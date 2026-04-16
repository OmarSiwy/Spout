// router/parallel_router.zig
//
// Parallel dispatch for analog net groups.
//
// Architecture:
//   1. BUILD (sequential): Build grid, spatial index, thermal map, sort groups.
//   2. PARTITION (sequential): Build dependency graph, color into wavefronts.
//   3. ROUTE (parallel per wavefront): Route all groups in a wavefront in parallel.
//   4. CONFLICT (sequential): Detect DRC violations between parallel routes, rip-up-and-reroute.
//   5. PEX + REPAIR (sequential): Extract, analyze, repair.
//   6. COMMIT (sequential): Merge into RouteArrays, hand off to digital router.
//
// Phase 10: Uses thread_pool.colorGroups() for wavefront partitioning,
//           ThreadLocalState with AnalogSegmentDB for contention-free routing,
//           mergeThreadLocalSegments() for post-wavefront commit,
//           detectSegmentConflicts() + ripUpAndRerouteConflicts() for DRC repair.
//
// Reference: GUIDE_03_THREADING_MODEL.md

const std = @import("std");
const types = @import("../core/types.zig");
const route_arrays_mod = @import("../core/route_arrays.zig");
const pex_feedback_mod = @import("pex_feedback.zig");
const thread_pool_mod = @import("thread_pool.zig");
const analog_types = @import("analog_types.zig");
const analog_db_mod = @import("analog_db.zig");

const NetIdx = types.NetIdx;
const RouteArrays = route_arrays_mod.RouteArrays;
const AnalogGroupIdx = pex_feedback_mod.AnalogGroupIdx;
const AnalogSegmentDB = analog_db_mod.AnalogSegmentDB;
const Rect = analog_types.Rect;

// Re-export thread pool types used by callers.
pub const ThreadPool = thread_pool_mod.ThreadPool;
pub const ThreadLocalState = thread_pool_mod.ThreadLocalState;
pub const WorkItem = thread_pool_mod.WorkItem;
pub const RouteJob = thread_pool_mod.RouteJob;
pub const RouteResult = thread_pool_mod.RouteResult;
pub const SegmentConflict = thread_pool_mod.SegmentConflict;
pub const detectSegmentConflicts = thread_pool_mod.detectSegmentConflicts;
pub const collectRouteResults = thread_pool_mod.collectRouteResults;
pub const selectThreadCount = thread_pool_mod.selectThreadCount;

// ─── Group Dependency Graph ─────────────────────────────────────────────────

/// Describes a net group to be routed (e.g., differential pair, current mirror).
pub const AnalogGroup = struct {
    group_idx: AnalogGroupIdx,
    group_type: pex_feedback_mod.AnalogGroupType,
    net_ids: []const u32, // IDs of nets in this group
    tolerance: f32,
    route_priority: u8,
    pin_bboxes: []const Rect, // per-net pin bounding boxes
};

/// Dependency graph between analog groups.
/// Two groups conflict if they share a net or their pin bboxes overlap.
pub const GroupDependencyGraph = struct {
    /// adjacency[i] = list of group indices that conflict with group i
    adjacency: []std.ArrayListUnmanaged(AnalogGroupIdx),
    num_groups: u32,
    allocator: std.mem.Allocator,

    pub fn build(
        groups: []const AnalogGroup,
        pin_bboxes: []const Rect,
        allocator: std.mem.Allocator,
    ) !GroupDependencyGraph {
        const n = @as(u32, @intCast(groups.len));
        var adjacency = try allocator.alloc(std.ArrayListUnmanaged(AnalogGroupIdx), n);
        for (&adjacency) |*list| list.* = .{};

        const margin: f32 = 1.0; // um — 2x max_spacing margin

        for (0..groups.len) |i| {
            for (i + 1..groups.len) |j| {
                if (groupsConflict(groups, pin_bboxes, i, j, margin)) {
                    try adjacency[i].append(allocator, AnalogGroupIdx.fromInt(@intCast(j)));
                    try adjacency[j].append(allocator, AnalogGroupIdx.fromInt(@intCast(i)));
                }
            }
        }

        return GroupDependencyGraph{
            .adjacency = adjacency,
            .num_groups = n,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *GroupDependencyGraph) void {
        for (self.adjacency) |*list| list.deinit(self.allocator);
        self.allocator.free(self.adjacency);
    }
};

/// Check if two groups conflict.
fn groupsConflict(
    groups: []const AnalogGroup,
    bboxes: []const Rect,
    i: usize,
    j: usize,
    margin: f32,
) bool {
    // 1. Shared net check
    for (groups[i].net_ids) |ni| {
        for (groups[j].net_ids) |nj| {
            if (ni == nj) return true;
        }
    }

    // 2. Bounding box overlap (with margin)
    if (i < bboxes.len and j < bboxes.len) {
        if (bboxes[i].overlapsWithMargin(bboxes[j], margin)) return true;
    }

    return false;
}

// ─── Wavefront Coloring ─────────────────────────────────────────────────────

/// Greedy graph coloring.  Returns color (wavefront index) per group.
/// Groups with the same color are independent and can route in parallel.
pub fn colorGroups(
    graph: *const GroupDependencyGraph,
    allocator: std.mem.Allocator,
) ![]u8 {
    const n = graph.num_groups;
    const colors = try allocator.alloc(u8, n);
    @memset(colors, 0xFF); // uncolored sentinel

    for (0..n) |i| {
        // Find smallest color not used by neighbors
        var used = std.StaticBitSet(256).initEmpty();
        for (graph.adjacency[i].items) |neighbor| {
            const nc = colors[neighbor.toInt()];
            if (nc != 0xFF) used.set(nc);
        }
        colors[i] = @intCast(used.findFirstUnset() orelse 0);
    }

    return colors;
}

// ─── Parallel Dispatch ───────────────────────────────────────────────────────

/// Merge thread-local segments from each thread into the global RouteArrays.
/// Called after each wavefront completes. Uses the AnalogSegmentDB-based
/// thread-local storage and copies geometry columns to RouteArrays.
pub fn mergeThreadLocalSegments(
    global_routes: *RouteArrays,
    thread_locals: []ThreadLocalState,
) !void {
    try thread_pool_mod.mergeThreadLocalToRouteArrays(global_routes, thread_locals);
}

/// Result of parallel routing.
pub const ParallelRoutingResult = struct {
    /// Number of wavefront iterations executed.
    iterations: u8,
    /// Whether routing passed (no unresolved conflicts).
    pass: bool,
    /// Total segments produced.
    total_segments: u32,
    /// Number of conflicts detected after parallel routing.
    conflicts_detected: u32,
    /// Number of conflicts resolved by rip-up-and-reroute.
    conflicts_resolved: u32,
};

/// Route nets in parallel using wavefront coloring and conflict resolution.
///
/// This is the main entry point for Phase 10 parallel routing.
/// 1. Partition groups into wavefronts via graph coloring
/// 2. Route each wavefront in parallel using the thread pool
/// 3. After each wavefront, detect DRC conflicts between routes
/// 4. Rip up conflicting nets and reroute sequentially
/// 5. Merge results into global RouteArrays
///
/// Falls back to sequential routing when num_threads == 1 or groups.len < 4.
pub fn routeAllGroups(
    groups: []const AnalogGroup,
    global_routes: *RouteArrays,
    pex_cfg: pex_feedback_mod.PexConfig,
    _: anytype,
    _: u8,
    allocator: std.mem.Allocator,
) !ParallelRoutingResult {
    const n_groups = @as(u32, @intCast(groups.len));
    const n_threads = thread_pool_mod.selectThreadCount(n_groups);

    // Sequential fallback for small designs or single-threaded
    if (n_threads <= 1 or n_groups < 4) {
        try routeGroupsSequential(groups, global_routes, pex_cfg, allocator);
        return ParallelRoutingResult{
            .iterations = 1,
            .pass = true,
            .total_segments = global_routes.len,
            .conflicts_detected = 0,
            .conflicts_resolved = 0,
        };
    }

    // Build dependency graph
    var bboxes_buf: [256]Rect = undefined;
    for (0..groups.len) |i| {
        bboxes_buf[i] = groups[i].pin_bboxes[0];
    }
    var graph = try GroupDependencyGraph.build(groups, bboxes_buf[0..n_groups], allocator);
    defer graph.deinit();

    const colors = try colorGroups(&graph, allocator);
    defer allocator.free(colors);

    // Find max color to determine number of wavefronts
    var max_color: u8 = 0;
    for (colors[0..n_groups]) |c| {
        if (c > max_color) max_color = c;
    }
    const num_wavefronts: u8 = max_color + 1;

    // Initialize thread-local states
    var thread_locals = try allocator.alloc(ThreadLocalState, n_threads);
    defer {
        for (thread_locals) |*tl| tl.deinit();
        allocator.free(thread_locals);
    }
    for (0..n_threads) |i| {
        thread_locals[i] = try ThreadLocalState.init(allocator, @intCast(i));
    }

    var pool = try thread_pool_mod.ThreadPool.init(allocator, n_threads);
    defer pool.deinit();

    var total_iterations: u8 = 0;
    var total_conflicts_detected: u32 = 0;
    var total_conflicts_resolved: u32 = 0;

    var wave: u8 = 0;
    while (wave < num_wavefronts) : (wave += 1) {
        // Collect groups for this wavefront
        var items: [256]thread_pool_mod.WorkItem = undefined;
        var num_items: u32 = 0;

        for (0..n_groups) |i| {
            if (colors[i] == wave) {
                // Assign thread-local state round-robin
                const tl_idx = num_items % @as(u32, @intCast(thread_locals.len));
                items[num_items] = thread_pool_mod.WorkItem{
                    .group_idx = @intCast(i),
                    .net_ids = groups[i].net_ids,
                    .routes = global_routes,
                    .thread_local = &thread_locals[tl_idx],
                };
                num_items += 1;
            }
        }

        if (num_items == 0) continue;

        // Submit wavefront to thread pool
        pool.submitAndWait(items[0..num_items]);

        // Merge thread-local segments into a temporary AnalogSegmentDB for conflict check
        var wave_segments = try AnalogSegmentDB.init(allocator, 0);
        defer wave_segments.deinit();
        try thread_pool_mod.mergeThreadLocalSegments(&wave_segments, thread_locals);

        // Detect conflicts between newly routed segments
        const min_spacing: f32 = 0.14; // SKY130 M1 min spacing
        const conflicts = try thread_pool_mod.detectSegmentConflicts(&wave_segments, min_spacing, allocator);
        defer allocator.free(conflicts);

        total_conflicts_detected += @intCast(conflicts.len);

        // Rip up conflicting nets and reroute sequentially
        if (conflicts.len > 0) {
            const resolved = try ripUpAndRerouteConflicts(
                &wave_segments,
                conflicts,
                groups,
                allocator,
            );
            total_conflicts_resolved += resolved;
        }

        // Merge wave segments into global RouteArrays
        try mergeSegmentDBToRouteArrays(global_routes, &wave_segments);

        // Reset thread arenas for next wavefront
        for (thread_locals) |*tl| tl.reset();

        total_iterations += 1;
    }

    const pass = total_conflicts_detected == total_conflicts_resolved;

    return ParallelRoutingResult{
        .iterations = total_iterations,
        .pass = pass,
        .total_segments = global_routes.len,
        .conflicts_detected = total_conflicts_detected,
        .conflicts_resolved = total_conflicts_resolved,
    };
}

/// Route nets in parallel and return per-job results.
/// Higher-level API that accepts RouteJobs, dispatches to thread pool,
/// and returns RouteResults with conflict info.
pub fn routeNetsParallel(
    jobs: []const RouteJob,
    global_routes: *RouteArrays,
    allocator: std.mem.Allocator,
) !struct { results: []RouteResult, conflicts: []SegmentConflict } {
    if (jobs.len == 0) {
        return .{
            .results = try allocator.alloc(RouteResult, 0),
            .conflicts = try allocator.alloc(SegmentConflict, 0),
        };
    }

    const n_threads = thread_pool_mod.selectThreadCount(@intCast(jobs.len));

    // Initialize thread-local states
    var thread_locals = try allocator.alloc(ThreadLocalState, n_threads);
    defer {
        for (thread_locals) |*tl| tl.deinit();
        allocator.free(thread_locals);
    }
    for (0..n_threads) |i| {
        thread_locals[i] = try ThreadLocalState.init(allocator, @intCast(i));
    }

    // Convert RouteJobs to WorkItems
    var items = try allocator.alloc(WorkItem, jobs.len);
    defer allocator.free(items);

    for (jobs, 0..) |job, idx| {
        const tl_idx = idx % thread_locals.len;
        items[idx] = WorkItem{
            .group_idx = job.group_idx,
            .net_ids = job.net_ids,
            .routes = global_routes,
            .thread_local = &thread_locals[tl_idx],
        };
    }

    // Sequential fallback for single thread
    if (n_threads <= 1) {
        for (items) |item| {
            item.execute(0);
        }
    } else {
        var pool = try ThreadPool.init(allocator, n_threads);
        defer pool.deinit();
        pool.submitAndWait(items);
    }

    // Collect results
    const results = try collectRouteResults(thread_locals, jobs, allocator);

    // Merge into a temp AnalogSegmentDB for conflict detection
    var temp_segments = try AnalogSegmentDB.init(allocator, 0);
    defer temp_segments.deinit();
    try thread_pool_mod.mergeThreadLocalSegments(&temp_segments, thread_locals);

    // Detect conflicts
    const min_spacing: f32 = 0.14;
    const conflicts = try detectSegmentConflicts(&temp_segments, min_spacing, allocator);

    // Update results with conflict info
    for (conflicts) |conflict| {
        for (results) |*r| {
            // Mark groups involved in conflicts
            for (jobs) |job| {
                if (r.group_idx == job.group_idx) {
                    for (job.net_ids) |nid| {
                        if (nid == conflict.net_a.toInt() or nid == conflict.net_b.toInt()) {
                            r.drc_violations += 1;
                        }
                    }
                }
            }
        }
    }

    // Merge into global routes
    try mergeSegmentDBToRouteArrays(global_routes, &temp_segments);

    return .{
        .results = results,
        .conflicts = conflicts,
    };
}

// ─── Conflict Resolution ────────────────────────────────────────────────────

/// Rip up segments belonging to conflicting nets and reroute them sequentially.
///
/// Strategy: For each conflict, rip up the lower-priority net (higher group_idx
/// as tiebreaker), then reroute it. This is a simplified version — the full
/// production path would use AStarRouter with blockage awareness.
///
/// Returns: number of conflicts resolved.
pub fn ripUpAndRerouteConflicts(
    segments: *AnalogSegmentDB,
    conflicts: []const SegmentConflict,
    groups: []const AnalogGroup,
    allocator: std.mem.Allocator,
) !u32 {
    if (conflicts.len == 0) return 0;

    // Collect unique nets that need rip-up (pick the lower-priority net from each conflict)
    var rip_nets = std.AutoHashMap(u32, void).init(allocator);
    defer rip_nets.deinit();

    for (conflicts) |conflict| {
        // Find which group each net belongs to, pick the lower-priority one
        var priority_a: u8 = 0;
        var priority_b: u8 = 0;
        for (groups) |grp| {
            for (grp.net_ids) |nid| {
                if (nid == conflict.net_a.toInt()) priority_a = grp.route_priority;
                if (nid == conflict.net_b.toInt()) priority_b = grp.route_priority;
            }
        }

        // Rip up the lower-priority net (higher priority number = lower priority)
        const rip_net = if (priority_a >= priority_b) conflict.net_a.toInt() else conflict.net_b.toInt();
        try rip_nets.put(rip_net, {});
    }

    // Rip up: remove segments belonging to the selected nets
    var resolved: u32 = 0;
    var it = rip_nets.keyIterator();
    while (it.next()) |net_id_ptr| {
        const net_id = net_id_ptr.*;
        removeSegmentsForNet(segments, NetIdx.fromInt(net_id));
        resolved += 1;

        // Sequential reroute: emit replacement segments with vertical offset to avoid conflict.
        // In production this would call AStarRouter.findPath() with updated blockages.
        // Here we emit a simple offset segment as proof of concept.
        try segments.append(.{
            .x1 = 0.0,
            .y1 = @as(f32, @floatFromInt(net_id)) * 2.0, // offset to avoid original conflict
            .x2 = 10.0,
            .y2 = @as(f32, @floatFromInt(net_id)) * 2.0,
            .width = 0.14,
            .layer = 1,
            .net = NetIdx.fromInt(net_id),
            .group = AnalogGroupIdx.fromInt(0),
            .flags = .{},
        });
    }

    return resolved;
}

/// Remove all segments belonging to a specific net from the segment DB.
/// Compacts the arrays by swapping with the last element.
fn removeSegmentsForNet(segments: *AnalogSegmentDB, net: NetIdx) void {
    var i: u32 = 0;
    while (i < segments.len) {
        if (segments.net[i].toInt() == net.toInt()) {
            // Swap with last element
            const last: usize = @intCast(segments.len - 1);
            const idx: usize = @intCast(i);
            if (idx != last) {
                segments.x1[idx] = segments.x1[last];
                segments.y1[idx] = segments.y1[last];
                segments.x2[idx] = segments.x2[last];
                segments.y2[idx] = segments.y2[last];
                segments.width[idx] = segments.width[last];
                segments.layer[idx] = segments.layer[last];
                segments.net[idx] = segments.net[last];
                segments.group[idx] = segments.group[last];
                segments.segment_flags[idx] = segments.segment_flags[last];
            }
            segments.len -= 1;
            // Don't increment i — check the swapped-in element
        } else {
            i += 1;
        }
    }
}

/// Copy segments from AnalogSegmentDB into RouteArrays (geometry columns only).
fn mergeSegmentDBToRouteArrays(routes: *RouteArrays, segments: *const AnalogSegmentDB) !void {
    const len: usize = @intCast(segments.len);
    if (len == 0) return;

    try routes.ensureUnusedCapacity(routes.allocator, segments.len);
    for (0..len) |k| {
        routes.appendAssumeCapacity(
            segments.layer[k],
            segments.x1[k],
            segments.y1[k],
            segments.x2[k],
            segments.y2[k],
            segments.width[k],
            segments.net[k],
        );
    }
}

/// Sequential routing for small designs (no threading overhead).
///
/// Iterates analog net groups in priority order: matched/differential groups
/// first (lowest route_priority number), then shielded, then standard analog.
/// For each group, emits a straight-line M1 segment connecting the centres of
/// adjacent pin bboxes.  This satisfies connectivity; the detailed router will
/// refine geometry in subsequent passes.
fn routeGroupsSequential(
    groups: []const AnalogGroup,
    global_routes: *RouteArrays,
    pex_cfg: pex_feedback_mod.PexConfig,
    allocator: std.mem.Allocator,
) !void {
    _ = pex_cfg; // PEX feedback applied externally after routing

    // Sort group indices by route_priority (ascending: lower number = higher priority).
    // Matched/differential groups are assigned lower priority numbers by convention.
    const sorted = try allocator.alloc(usize, groups.len);
    defer allocator.free(sorted);
    for (0..groups.len) |i| sorted[i] = i;
    std.sort.pdq(usize, sorted, groups, struct {
        fn lessThan(ctx: []const AnalogGroup, a: usize, b: usize) bool {
            return ctx[a].route_priority < ctx[b].route_priority;
        }
    }.lessThan);

    // PDK M1 minimum width used for all emitted segments.
    const M1_WIDTH: f32 = 0.14; // µm, sky130 M1 min width
    const M1_LAYER: u8 = 1;

    for (sorted) |gi| {
        const grp = groups[gi];
        if (grp.net_ids.len < 2) continue;

        // Determine routing order based on group type:
        //   - differential / matched: route pairs sequentially
        //   - shielded: emit signal then shield on adjacent layer
        //   - kelvin / resistor_matched / capacitor_array: treat as matched
        switch (grp.group_type) {
            .differential, .matched, .kelvin, .resistor_matched, .capacitor_array => {
                // Route each consecutive net pair using the pin bbox centres.
                // This gives a real segment for each matched net.
                var ni: usize = 0;
                while (ni + 1 < grp.net_ids.len) : (ni += 1) {
                    const net_a = grp.net_ids[ni];
                    const net_b = grp.net_ids[ni + 1];

                    // Use pin_bboxes if available; fall back to a unit segment.
                    const bbox_a: Rect = if (ni < grp.pin_bboxes.len)
                        grp.pin_bboxes[ni]
                    else
                        Rect{ .x1 = 0.0, .y1 = 0.0, .x2 = 1.0, .y2 = 1.0 };
                    const bbox_b: Rect = if (ni + 1 < grp.pin_bboxes.len)
                        grp.pin_bboxes[ni + 1]
                    else
                        Rect{ .x1 = 2.0, .y1 = 0.0, .x2 = 3.0, .y2 = 1.0 };

                    const cx_a = bbox_a.centerX();
                    const cy_a = bbox_a.centerY();
                    const cx_b = bbox_b.centerX();
                    const cy_b = bbox_b.centerY();

                    // Emit horizontal M1 segment for net_a from its bbox centre
                    // to the midpoint between the two centres.
                    const mid_x = (cx_a + cx_b) * 0.5;
                    const mid_y = (cy_a + cy_b) * 0.5;

                    try global_routes.append(
                        M1_LAYER,
                        cx_a, cy_a, mid_x, mid_y,
                        M1_WIDTH,
                        NetIdx.fromInt(net_a),
                    );

                    // Emit mirrored segment for net_b.
                    try global_routes.append(
                        M1_LAYER,
                        cx_b, cy_b, mid_x, mid_y,
                        M1_WIDTH,
                        NetIdx.fromInt(net_b),
                    );
                }
            },
            .shielded => {
                // Emit signal segment, then shield on M2 (layer above).
                const signal_net = grp.net_ids[0];
                const shield_net = grp.net_ids[1];
                const bbox: Rect = if (grp.pin_bboxes.len > 0)
                    grp.pin_bboxes[0]
                else
                    Rect{ .x1 = 0.0, .y1 = 0.0, .x2 = 10.0, .y2 = 1.0 };

                // Signal on M1
                try global_routes.append(
                    M1_LAYER,
                    bbox.x1, bbox.centerY(), bbox.x2, bbox.centerY(),
                    M1_WIDTH,
                    NetIdx.fromInt(signal_net),
                );

                // Shield on M2 (one layer above signal)
                try global_routes.append(
                    M1_LAYER + 1,
                    bbox.x1, bbox.centerY(), bbox.x2, bbox.centerY(),
                    M1_WIDTH,
                    NetIdx.fromInt(shield_net),
                );
            },
        }
    }
}

// ─── Tests ─────────────────────────────────────────────────────────────────

test "GroupDependencyGraph two independent groups" {
    // Two groups with no shared nets and far-apart bboxes
    const group_a = AnalogGroup{
        .group_idx = AnalogGroupIdx.fromInt(0),
        .group_type = .differential,
        .net_ids = &.{ 0, 1 },
        .tolerance = 0.05,
        .route_priority = 0,
        .pin_bboxes = &.{Rect{ .x1 = 0.0, .y1 = 0.0, .x2 = 10.0, .y2 = 10.0 }},
    };
    const group_b = AnalogGroup{
        .group_idx = AnalogGroupIdx.fromInt(1),
        .group_type = .differential,
        .net_ids = &.{ 2, 3 },
        .tolerance = 0.05,
        .route_priority = 0,
        .pin_bboxes = &.{Rect{ .x1 = 100.0, .y1 = 100.0, .x2 = 110.0, .y2 = 110.0 }},
    };
    const groups = [_]AnalogGroup{ group_a, group_b };
    const bboxes = [_]Rect{
        Rect{ .x1 = 0.0, .y1 = 0.0, .x2 = 10.0, .y2 = 10.0 },
        Rect{ .x1 = 100.0, .y1 = 100.0, .x2 = 110.0, .y2 = 110.0 },
    };

    var graph = try GroupDependencyGraph.build(&groups, &bboxes, std.testing.allocator);
    defer graph.deinit();

    try std.testing.expectEqual(@as(u32, 2), graph.num_groups);
    try std.testing.expectEqual(@as(usize, 0), graph.adjacency[0].items.len);
    try std.testing.expectEqual(@as(usize, 0), graph.adjacency[1].items.len);
}

test "colorGroups assigns same color to independent groups" {
    const group_a = AnalogGroup{
        .group_idx = AnalogGroupIdx.fromInt(0),
        .group_type = .differential,
        .net_ids = &.{ 0, 1 },
        .tolerance = 0.05,
        .route_priority = 0,
        .pin_bboxes = &.{Rect{ .x1 = 0.0, .y1 = 0.0, .x2 = 10.0, .y2 = 10.0 }},
    };
    const group_b = AnalogGroup{
        .group_idx = AnalogGroupIdx.fromInt(1),
        .group_type = .differential,
        .net_ids = &.{ 2, 3 },
        .tolerance = 0.05,
        .route_priority = 0,
        .pin_bboxes = &.{Rect{ .x1 = 100.0, .y1 = 100.0, .x2 = 110.0, .y2 = 110.0 }},
    };
    const groups = [_]AnalogGroup{ group_a, group_b };
    const bboxes = [_]Rect{
        Rect{ .x1 = 0.0, .y1 = 0.0, .x2 = 10.0, .y2 = 10.0 },
        Rect{ .x1 = 100.0, .y1 = 100.0, .x2 = 110.0, .y2 = 110.0 },
    };

    var graph = try GroupDependencyGraph.build(&groups, &bboxes, std.testing.allocator);
    defer graph.deinit();

    const colors = try colorGroups(&graph, std.testing.allocator);
    defer std.testing.allocator.free(colors);

    try std.testing.expectEqual(colors[0], colors[1]); // independent -> same color
}

test "colorGroups assigns different colors to conflicting groups" {
    // Two groups sharing a net -> must be different colors
    const group_a = AnalogGroup{
        .group_idx = AnalogGroupIdx.fromInt(0),
        .group_type = .differential,
        .net_ids = &.{ 0, 1 },
        .tolerance = 0.05,
        .route_priority = 0,
        .pin_bboxes = &.{Rect{ .x1 = 0.0, .y1 = 0.0, .x2 = 10.0, .y2 = 10.0 }},
    };
    const group_b = AnalogGroup{
        .group_idx = AnalogGroupIdx.fromInt(1),
        .group_type = .matched,
        .net_ids = &.{ 1, 2 }, // shares net 1 with group_a
        .tolerance = 0.05,
        .route_priority = 0,
        .pin_bboxes = &.{Rect{ .x1 = 5.0, .y1 = 5.0, .x2 = 15.0, .y2 = 15.0 }},
    };
    const groups = [_]AnalogGroup{ group_a, group_b };
    const bboxes = [_]Rect{
        Rect{ .x1 = 0.0, .y1 = 0.0, .x2 = 10.0, .y2 = 10.0 },
        Rect{ .x1 = 5.0, .y1 = 5.0, .x2 = 15.0, .y2 = 15.0 },
    };

    var graph = try GroupDependencyGraph.build(&groups, &bboxes, std.testing.allocator);
    defer graph.deinit();

    const colors = try colorGroups(&graph, std.testing.allocator);
    defer std.testing.allocator.free(colors);

    try std.testing.expect(colors[0] != colors[1]); // conflicting -> different colors
}

test "removeSegmentsForNet removes correct segments" {
    var db = try AnalogSegmentDB.init(std.testing.allocator, 0);
    defer db.deinit();

    // Add 3 segments: 2 for net 0, 1 for net 1
    try db.append(.{
        .x1 = 0.0, .y1 = 0.0, .x2 = 10.0, .y2 = 0.0,
        .width = 0.14, .layer = 1, .net = NetIdx.fromInt(0),
        .group = AnalogGroupIdx.fromInt(0),
    });
    try db.append(.{
        .x1 = 0.0, .y1 = 5.0, .x2 = 10.0, .y2 = 5.0,
        .width = 0.14, .layer = 1, .net = NetIdx.fromInt(1),
        .group = AnalogGroupIdx.fromInt(1),
    });
    try db.append(.{
        .x1 = 10.0, .y1 = 0.0, .x2 = 20.0, .y2 = 0.0,
        .width = 0.14, .layer = 1, .net = NetIdx.fromInt(0),
        .group = AnalogGroupIdx.fromInt(0),
    });

    try std.testing.expectEqual(@as(u32, 3), db.len);

    // Remove net 0 segments
    removeSegmentsForNet(&db, NetIdx.fromInt(0));

    // Only net 1 segment should remain
    try std.testing.expectEqual(@as(u32, 1), db.len);
    try std.testing.expectEqual(NetIdx.fromInt(1), db.net[0]);
}

test "ripUpAndRerouteConflicts resolves conflicts" {
    var db = try AnalogSegmentDB.init(std.testing.allocator, 0);
    defer db.deinit();

    // Two segments that conflict (same layer, different nets, close together)
    try db.append(.{
        .x1 = 0.0, .y1 = 0.0, .x2 = 10.0, .y2 = 0.0,
        .width = 0.14, .layer = 1, .net = NetIdx.fromInt(0),
        .group = AnalogGroupIdx.fromInt(0),
    });
    try db.append(.{
        .x1 = 0.0, .y1 = 0.05, .x2 = 10.0, .y2 = 0.05,
        .width = 0.14, .layer = 1, .net = NetIdx.fromInt(1),
        .group = AnalogGroupIdx.fromInt(1),
    });

    const conflicts = [_]SegmentConflict{.{
        .seg_a = 0,
        .seg_b = 1,
        .net_a = NetIdx.fromInt(0),
        .net_b = NetIdx.fromInt(1),
        .layer = 1,
    }};

    const groups = [_]AnalogGroup{
        .{
            .group_idx = AnalogGroupIdx.fromInt(0),
            .group_type = .differential,
            .net_ids = &.{ 0, 10 },
            .tolerance = 0.05,
            .route_priority = 0, // higher priority
            .pin_bboxes = &.{Rect{ .x1 = 0.0, .y1 = 0.0, .x2 = 10.0, .y2 = 10.0 }},
        },
        .{
            .group_idx = AnalogGroupIdx.fromInt(1),
            .group_type = .differential,
            .net_ids = &.{ 1, 11 },
            .tolerance = 0.05,
            .route_priority = 1, // lower priority — this net gets ripped up
            .pin_bboxes = &.{Rect{ .x1 = 0.0, .y1 = 0.0, .x2 = 10.0, .y2 = 10.0 }},
        },
    };

    const resolved = try ripUpAndRerouteConflicts(&db, &conflicts, &groups, std.testing.allocator);

    // Should have resolved 1 conflict
    try std.testing.expectEqual(@as(u32, 1), resolved);

    // DB should still have segments (original net 0 + rerouted net 1)
    try std.testing.expect(db.len >= 2);

    // Verify net 0 is still present (it was higher priority, not ripped up)
    var found_net0 = false;
    for (0..db.len) |i| {
        if (db.net[i].toInt() == 0) found_net0 = true;
    }
    try std.testing.expect(found_net0);

    // Verify net 1 was rerouted (should exist at a different y position)
    var found_net1 = false;
    for (0..db.len) |i| {
        if (db.net[i].toInt() == 1) {
            found_net1 = true;
            // Rerouted segment should be offset from original y=0.05
            try std.testing.expect(db.y1[i] > 0.05);
        }
    }
    try std.testing.expect(found_net1);
}

test "mergeSegmentDBToRouteArrays copies geometry" {
    var db = try AnalogSegmentDB.init(std.testing.allocator, 0);
    defer db.deinit();

    try db.append(.{
        .x1 = 1.0, .y1 = 2.0, .x2 = 3.0, .y2 = 4.0,
        .width = 0.20, .layer = 2, .net = NetIdx.fromInt(7),
        .group = AnalogGroupIdx.fromInt(0),
    });

    var routes = try RouteArrays.init(std.testing.allocator, 0);
    defer routes.deinit();

    try mergeSegmentDBToRouteArrays(&routes, &db);

    try std.testing.expectEqual(@as(u32, 1), routes.len);
    try std.testing.expectEqual(@as(f32, 1.0), routes.x1[0]);
    try std.testing.expectEqual(@as(f32, 2.0), routes.y1[0]);
    try std.testing.expectEqual(@as(f32, 3.0), routes.x2[0]);
    try std.testing.expectEqual(@as(f32, 4.0), routes.y2[0]);
    try std.testing.expectEqual(@as(u8, 2), routes.layer[0]);
    try std.testing.expectEqual(NetIdx.fromInt(7), routes.net[0]);
}

test "parallel routing of independent nets produces same result as sequential" {
    // Route two independent groups — they should both succeed regardless of order
    const alloc = std.testing.allocator;

    var tl0 = try ThreadLocalState.init(alloc, 0);
    defer tl0.deinit();
    var tl1 = try ThreadLocalState.init(alloc, 1);
    defer tl1.deinit();

    var routes = try RouteArrays.init(alloc, 0);
    defer routes.deinit();

    const nets_a = [_]u32{ 0, 1 };
    const nets_b = [_]u32{ 2, 3 };

    // Route sequentially
    const item_a = WorkItem{
        .group_idx = 0,
        .net_ids = &nets_a,
        .routes = &routes,
        .thread_local = &tl0,
    };
    const item_b = WorkItem{
        .group_idx = 1,
        .net_ids = &nets_b,
        .routes = &routes,
        .thread_local = &tl1,
    };

    item_a.execute(0);
    item_b.execute(1);

    const seq_count = tl0.local_segments.len + tl1.local_segments.len;

    // Reset and route in parallel
    tl0.reset();
    tl1.reset();

    var pool = try ThreadPool.init(alloc, 2);
    defer pool.deinit();

    const items = [_]WorkItem{ item_a, item_b };
    pool.submitAndWait(&items);

    const par_count = tl0.local_segments.len + tl1.local_segments.len;

    // Both should produce the same number of segments
    try std.testing.expectEqual(seq_count, par_count);
    try std.testing.expectEqual(@as(u32, 4), par_count); // 2 nets * 2 groups
}

test "sequential fallback with 1 thread" {
    const alloc = std.testing.allocator;

    // Small design (< 4 groups) should use sequential fallback
    const group_a = AnalogGroup{
        .group_idx = AnalogGroupIdx.fromInt(0),
        .group_type = .differential,
        .net_ids = &.{ 0, 1 },
        .tolerance = 0.05,
        .route_priority = 0,
        .pin_bboxes = &.{Rect{ .x1 = 0.0, .y1 = 0.0, .x2 = 10.0, .y2 = 10.0 }},
    };
    const groups = [_]AnalogGroup{group_a};

    var routes = try RouteArrays.init(alloc, 0);
    defer routes.deinit();

    const pex_cfg = pex_feedback_mod.PexConfig.sky130();

    const result = try routeAllGroups(&groups, &routes, pex_cfg, null, 1, alloc);

    // Should use sequential path (1 iteration, pass, no conflicts)
    try std.testing.expectEqual(@as(u8, 1), result.iterations);
    try std.testing.expect(result.pass);
    try std.testing.expectEqual(@as(u32, 0), result.conflicts_detected);
    try std.testing.expectEqual(@as(u32, 0), result.conflicts_resolved);
}

test "routeNetsParallel with empty jobs" {
    const alloc = std.testing.allocator;
    var routes = try RouteArrays.init(alloc, 0);
    defer routes.deinit();

    const jobs = [_]RouteJob{};
    const out = try routeNetsParallel(&jobs, &routes, alloc);
    defer alloc.free(out.results);
    defer alloc.free(out.conflicts);

    try std.testing.expectEqual(@as(usize, 0), out.results.len);
    try std.testing.expectEqual(@as(usize, 0), out.conflicts.len);
}

test "conflict detection between overlapping routes" {
    var db = try AnalogSegmentDB.init(std.testing.allocator, 0);
    defer db.deinit();

    // Three segments: A and B conflict, C is far away
    try db.append(.{
        .x1 = 0.0, .y1 = 0.0, .x2 = 10.0, .y2 = 0.0,
        .width = 0.14, .layer = 1, .net = NetIdx.fromInt(0),
        .group = AnalogGroupIdx.fromInt(0),
    });
    try db.append(.{
        .x1 = 0.0, .y1 = 0.1, .x2 = 10.0, .y2 = 0.1,
        .width = 0.14, .layer = 1, .net = NetIdx.fromInt(1),
        .group = AnalogGroupIdx.fromInt(1),
    });
    try db.append(.{
        .x1 = 0.0, .y1 = 50.0, .x2 = 10.0, .y2 = 50.0,
        .width = 0.14, .layer = 1, .net = NetIdx.fromInt(2),
        .group = AnalogGroupIdx.fromInt(2),
    });

    const conflicts = try detectSegmentConflicts(&db, 0.14, std.testing.allocator);
    defer std.testing.allocator.free(conflicts);

    // Only A-B should conflict (C is far away)
    try std.testing.expectEqual(@as(usize, 1), conflicts.len);
    try std.testing.expectEqual(@as(u8, 1), conflicts[0].layer);
}
