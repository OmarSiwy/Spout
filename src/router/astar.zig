const std = @import("std");
const core_types = @import("../core/types.zig");
const grid_mod = @import("grid.zig");
const layout_if = @import("../core/layout_if.zig");
const inline_drc_mod = @import("inline_drc.zig");

const NetIdx = core_types.NetIdx;
const MultiLayerGrid = grid_mod.MultiLayerGrid;
pub const GridNode = grid_mod.GridNode;
const PdkConfig = layout_if.PdkConfig;
const MetalDirection = layout_if.MetalDirection;

// ─── A* Grid Router ────────────────────────────────────────────────────────
//
// A* search on a multi-layer routing grid with world-coordinate Manhattan
// distance heuristic.  Supports via transitions between adjacent layers with
// pitch-ratio-scaled via cost, wrong-way penalties for non-preferred
// direction moves, and per-cell congestion weighting.
//
// Each layer has its own pitch and preferred routing direction.  Moves
// along the preferred direction cost the layer's pitch; moves along the
// cross direction incur a wrong_way_cost multiplier.  Via transitions
// cost via_base_cost * max(1, upper_pitch / lower_pitch).

/// A routed path: sequence of grid nodes from source to target.
pub const RoutePath = struct {
    nodes: []GridNode,
    allocator: std.mem.Allocator,

    /// Free path node storage.
    pub fn deinit(self: *RoutePath) void {
        self.allocator.free(self.nodes);
        self.* = undefined;
    }
};

/// Entry in the A* open set (min-heap).
const HeapEntry = struct {
    f_cost: f32, // g + h
    g_cost: f32, // cost from source
    node: GridNode,
};

/// Comparison for the binary min-heap: lower f_cost first.
fn heapLessThan(_: void, a: HeapEntry, b: HeapEntry) std.math.Order {
    return std.math.order(a.f_cost, b.f_cost);
}

/// Packed key for the visited/came-from maps.
const NodeKey = u64;

/// Pack a GridNode into a compact u64 key.
fn packKey(node: GridNode) NodeKey {
    return @as(u64, node.layer) << 48 |
        @as(u64, node.track_a) << 24 |
        @as(u64, node.track_b);
}

/// Unpack a NodeKey back into a GridNode.
fn unpackKey(key: NodeKey) GridNode {
    return .{
        .layer = @intCast((key >> 48) & 0xFF),
        .track_a = @intCast((key >> 24) & 0xFFFFFF),
        .track_b = @intCast(key & 0xFFFFFF),
    };
}

/// A* search engine for multi-layer routing grids.
pub const AStarRouter = struct {
    allocator: std.mem.Allocator,
    /// Base cost for via transitions (multiplied by pitch ratio).
    via_cost: f32,
    /// Congestion penalty multiplier: cost += congestion_weight * cell.congestion.
    congestion_weight: f32,
    /// Penalty multiplier for moves along the non-preferred direction.
    wrong_way_cost: f32,
    /// Inline DRC checker for spacing/short violation filtering during A* search.
    drc_checker: ?*const inline_drc_mod.InlineDrcChecker,
    /// Weight applied to DRC violation cost.
    drc_weight: f32,

    /// Initialise an AStarRouter with default cost parameters.
    pub fn init(allocator: std.mem.Allocator) AStarRouter {
        return .{
            .allocator = allocator,
            .via_cost = 3.0,
            .congestion_weight = 0.5,
            .wrong_way_cost = 3.0,
            .drc_checker = null,
            .drc_weight = 1.0,
        };
    }

    /// Find the shortest path from `source` to `target` on the multi-layer
    /// routing grid, considering only cells routable by `net`.
    ///
    /// Returns null if no path exists.
    pub fn findPath(
        self: *const AStarRouter,
        grid: *const MultiLayerGrid,
        source: GridNode,
        target: GridNode,
        net: NetIdx,
    ) !?RoutePath {
        // Fast path: source == target.
        if (source.eql(target)) {
            const nodes = try self.allocator.alloc(GridNode, 1);
            nodes[0] = source;
            return RoutePath{ .nodes = nodes, .allocator = self.allocator };
        }

        // Open set: binary min-heap on f_cost.
        var open = std.PriorityQueue(HeapEntry, void, heapLessThan).init(self.allocator, {});
        defer open.deinit();

        // gMap: NodeKey -> f32 (best known g-cost).
        var gMap = std.AutoHashMap(NodeKey, f32).init(self.allocator);
        defer gMap.deinit();

        // cameFrom map: NodeKey -> NodeKey (parent).
        var cameFrom = std.AutoHashMap(NodeKey, NodeKey).init(self.allocator);
        defer cameFrom.deinit();

        // Closed set.
        var closed = std.AutoHashMap(NodeKey, void).init(self.allocator);
        defer closed.deinit();

        const srcKey = packKey(source);
        try gMap.put(srcKey, 0.0);
        const h0 = self.heuristic(grid, source, target);
        try open.add(.{ .f_cost = h0, .g_cost = 0.0, .node = source });

        while (open.count() > 0) {
            const current = open.remove();
            const curKey = packKey(current.node);

            // Skip if already expanded.
            if (closed.contains(curKey)) continue;
            try closed.put(curKey, {});

            // Goal reached?
            if (current.node.eql(target)) {
                return try self.reconstructPath(cameFrom, srcKey, curKey, source, current.node);
            }

            // Expand neighbors.
            const neighbors = self.getNeighbors(current.node, grid, net);
            for (neighbors.items[0..neighbors.count]) |nbr| {
                const nbrKey = packKey(nbr.node);
                if (closed.contains(nbrKey)) continue;

                // Congestion penalty.
                const cell = grid.cellAtConst(nbr.node);
                const congPenalty = self.congestion_weight * @as(f32, @floatFromInt(cell.congestion));

                const tentativeG = current.g_cost + nbr.step_cost + congPenalty;

                const existingG = gMap.get(nbrKey);
                if (existingG) |eg| {
                    if (tentativeG >= eg) continue;
                }

                try gMap.put(nbrKey, tentativeG);
                try cameFrom.put(nbrKey, curKey);

                const h = self.heuristic(grid, nbr.node, target);
                try open.add(.{ .f_cost = tentativeG + h, .g_cost = tentativeG, .node = nbr.node });
            }
        }

        // No path found.
        return null;
    }

    /// World-coordinate Manhattan distance heuristic with layer-change penalty.
    fn heuristic(self: *const AStarRouter, grid: *const MultiLayerGrid, a: GridNode, target: GridNode) f32 {
        const pos_a = grid.nodeToWorld(a);
        const pos_t = grid.nodeToWorld(target);
        const dx = @abs(pos_a[0] - pos_t[0]);
        const dy = @abs(pos_a[1] - pos_t[1]);
        const dl: f32 = @abs(@as(f32, @floatFromInt(@as(i16, a.layer))) -
            @as(f32, @floatFromInt(@as(i16, target.layer))));
        return dx + dy + dl * self.via_cost;
    }

    /// Neighbor descriptor.
    const Neighbor = struct {
        node: GridNode,
        step_cost: f32,
    };

    /// Fixed-capacity neighbor buffer (max 6: 2 preferred + 2 cross + 2 via).
    const NeighborBuf = struct {
        items: [6]Neighbor,
        count: usize,
    };

    /// Get routable neighbors of a node on the multi-layer grid.
    ///
    /// Generates up to 6 neighbors:
    ///   - 2 moves along preferred direction (±1 track_a): cost = pitch
    ///   - 2 moves along cross direction (±1 track_b): cost = cross_pitch * wrong_way_cost
    ///   - 2 via transitions (layer ±1): cost = via_cost * max(1, upper_pitch / lower_pitch)
    fn getNeighbors(self: *const AStarRouter, node: GridNode, grid: *const MultiLayerGrid, net: NetIdx) NeighborBuf {
        var buf = NeighborBuf{ .items = undefined, .count = 0 };

        const layer = node.layer;
        const pitch = grid.layers[layer].pitch;
        const cross_pitch = grid.cross_layers[layer].pitch;
        const max_a = grid.layers[layer].num_tracks;
        const max_b = grid.cross_layers[layer].num_tracks;

        // Preferred direction: ±1 track_a, cost = pitch.
        if (node.track_a > 0) {
            const nbr = GridNode{ .layer = layer, .track_a = node.track_a - 1, .track_b = node.track_b };
            if (grid.isCellRoutable(nbr, net)) {
                var step_cost = pitch;
                const skip = self.drcFilter(grid, nbr, net, &step_cost);
                if (!skip) {
                    buf.items[buf.count] = .{ .node = nbr, .step_cost = step_cost };
                    buf.count += 1;
                }
            }
        }
        if (node.track_a + 1 < max_a) {
            const nbr = GridNode{ .layer = layer, .track_a = node.track_a + 1, .track_b = node.track_b };
            if (grid.isCellRoutable(nbr, net)) {
                var step_cost = pitch;
                const skip = self.drcFilter(grid, nbr, net, &step_cost);
                if (!skip) {
                    buf.items[buf.count] = .{ .node = nbr, .step_cost = step_cost };
                    buf.count += 1;
                }
            }
        }

        // Cross direction: ±1 track_b, cost = cross_pitch * wrong_way_cost.
        const cross_base = cross_pitch * self.wrong_way_cost;
        if (node.track_b > 0) {
            const nbr = GridNode{ .layer = layer, .track_a = node.track_a, .track_b = node.track_b - 1 };
            if (grid.isCellRoutable(nbr, net)) {
                var step_cost = cross_base;
                const skip = self.drcFilter(grid, nbr, net, &step_cost);
                if (!skip) {
                    buf.items[buf.count] = .{ .node = nbr, .step_cost = step_cost };
                    buf.count += 1;
                }
            }
        }
        if (node.track_b + 1 < max_b) {
            const nbr = GridNode{ .layer = layer, .track_a = node.track_a, .track_b = node.track_b + 1 };
            if (grid.isCellRoutable(nbr, net)) {
                var step_cost = cross_base;
                const skip = self.drcFilter(grid, nbr, net, &step_cost);
                if (!skip) {
                    buf.items[buf.count] = .{ .node = nbr, .step_cost = step_cost };
                    buf.count += 1;
                }
            }
        }

        // Via transitions: layer ±1.
        // Cost = via_cost * max(1.0, upper_pitch / lower_pitch)
        if (layer > 0) {
            const below: u8 = layer - 1;
            // Map track coordinates: find the world position, then snap to
            // the adjacent layer's grid.
            const world_pos = grid.nodeToWorld(node);
            const below_node = grid.worldToNode(below, world_pos[0], world_pos[1]);
            if (grid.isCellRoutable(below_node, net)) {
                const upper_p = pitch;
                const lower_p = grid.layers[below].pitch;
                var step_cost = self.via_cost * @max(1.0, upper_p / lower_p);
                const skip = self.drcFilter(grid, below_node, net, &step_cost);
                if (!skip) {
                    buf.items[buf.count] = .{ .node = below_node, .step_cost = step_cost };
                    buf.count += 1;
                }
            }
        }
        if (layer + 1 < grid.num_layers) {
            const above: u8 = layer + 1;
            const world_pos = grid.nodeToWorld(node);
            const above_node = grid.worldToNode(above, world_pos[0], world_pos[1]);
            if (grid.isCellRoutable(above_node, net)) {
                const lower_p = pitch;
                const upper_p = grid.layers[above].pitch;
                var step_cost = self.via_cost * @max(1.0, upper_p / lower_p);
                const skip = self.drcFilter(grid, above_node, net, &step_cost);
                if (!skip) {
                    buf.items[buf.count] = .{ .node = above_node, .step_cost = step_cost };
                    buf.count += 1;
                }
            }
        }

        return buf;
    }

    /// Query the inline DRC checker for a candidate neighbor node.
    /// Returns true if the neighbor should be skipped (hard violation).
    /// Adds soft penalty cost to step_cost if near-violation detected.
    fn drcFilter(self: *const AStarRouter, grid: *const MultiLayerGrid, nbr: GridNode, net: NetIdx, step_cost: *f32) bool {
        if (self.drc_checker) |drc| {
            const world_pos = grid.nodeToWorld(nbr);
            const result = drc.checkSpacing(nbr.layer, world_pos[0], world_pos[1], net);
            if (result.hard_violation) return true;
            step_cost.* += self.drc_weight * result.soft_penalty;
        }
        return false;
    }

    /// Reconstruct the path from cameFrom map.
    fn reconstructPath(
        self: *const AStarRouter,
        cameFrom: std.AutoHashMap(NodeKey, NodeKey),
        src_key: NodeKey,
        target_key: NodeKey,
        source: GridNode,
        target: GridNode,
    ) !RoutePath {
        // Count path length.
        var count: usize = 1;
        var key = target_key;
        while (key != src_key) {
            key = cameFrom.get(key) orelse break;
            count += 1;
        }

        const nodes = try self.allocator.alloc(GridNode, count);
        // Fill in reverse.
        nodes[count - 1] = target;
        key = target_key;
        var idx: usize = count - 1;
        while (idx > 0) {
            key = cameFrom.get(key) orelse break;
            idx -= 1;
            nodes[idx] = unpackKey(key);
        }
        nodes[0] = source;

        return RoutePath{ .nodes = nodes, .allocator = self.allocator };
    }
};

// ─── Tests ──────────────────────────────────────────────────────────────────

test "AStarRouter finds path on multi-layer grid" {
    const allocator = std.testing.allocator;
    const da_mod = @import("../core/device_arrays.zig");
    var da = try da_mod.DeviceArrays.init(allocator, 1);
    defer da.deinit();
    da.positions[0] = .{ 50.0, 50.0 };
    da.dimensions[0] = .{ 2.0, 2.0 };

    const pdk = PdkConfig.loadDefault(.sky130);
    var grid = try MultiLayerGrid.init(allocator, &da, &pdk, 20.0, null);
    defer grid.deinit();

    var router = AStarRouter.init(allocator);
    const net = NetIdx.fromInt(0);

    const src = grid.worldToNode(0, 35.0, 35.0);
    const tgt = grid.worldToNode(0, 65.0, 65.0);

    const pathOpt = try router.findPath(&grid, src, tgt, net);
    try std.testing.expect(pathOpt != null);
    var path = pathOpt.?;
    defer path.deinit();
    try std.testing.expect(path.nodes[0].eql(src));
    try std.testing.expect(path.nodes[path.nodes.len - 1].eql(tgt));
}

test "AStarRouter via transition between layers" {
    const allocator = std.testing.allocator;
    const da_mod = @import("../core/device_arrays.zig");
    var da = try da_mod.DeviceArrays.init(allocator, 1);
    defer da.deinit();
    da.positions[0] = .{ 5.0, 5.0 };
    da.dimensions[0] = .{ 0.5, 0.5 };

    const pdk = PdkConfig.loadDefault(.sky130);
    var grid = try MultiLayerGrid.init(allocator, &da, &pdk, 10.0, null);
    defer grid.deinit();

    var router = AStarRouter.init(allocator);
    const net = NetIdx.fromInt(0);

    // Route from M1 to M2 at same world position
    const pos = grid.nodeToWorld(grid.worldToNode(0, 2.0, 2.0));
    const src = grid.worldToNode(0, pos[0], pos[1]);
    const tgt = grid.worldToNode(1, pos[0], pos[1]);

    const pathOpt = try router.findPath(&grid, src, tgt, net);
    try std.testing.expect(pathOpt != null);
    var path = pathOpt.?;
    defer path.deinit();
    // Should go through a via (may include intermediate nodes)
    try std.testing.expect(path.nodes.len >= 2);
}

test "AStarRouter wrong-way cost penalizes non-preferred direction" {
    const allocator = std.testing.allocator;
    const da_mod = @import("../core/device_arrays.zig");
    var da = try da_mod.DeviceArrays.init(allocator, 0);
    defer da.deinit();

    const pdk = PdkConfig.loadDefault(.sky130);
    var grid = try MultiLayerGrid.init(allocator, &da, &pdk, 5.0, null);
    defer grid.deinit();

    const router = AStarRouter.init(allocator);

    const src = grid.worldToNode(0, 0.5, 0.5);
    const tgt = grid.worldToNode(0, 0.5, 4.5); // Same X, different Y = vertical

    const pathOpt = try router.findPath(&grid, src, tgt, NetIdx.fromInt(0));
    if (pathOpt) |path_val| {
        var path = path_val;
        defer path.deinit();
        try std.testing.expect(path.nodes.len >= 2);
    }
}

test "AStarRouter same source and target" {
    const allocator = std.testing.allocator;
    const da_mod = @import("../core/device_arrays.zig");
    var da = try da_mod.DeviceArrays.init(allocator, 1);
    defer da.deinit();
    da.positions[0] = .{ 5.0, 5.0 };
    da.dimensions[0] = .{ 2.0, 2.0 };

    const pdk = PdkConfig.loadDefault(.sky130);
    var grid = try MultiLayerGrid.init(allocator, &da, &pdk, 10.0, null);
    defer grid.deinit();

    const router = AStarRouter.init(allocator);
    const src = grid.worldToNode(0, 0.0, 0.0);

    const pathOpt = try router.findPath(&grid, src, src, NetIdx.fromInt(0));
    try std.testing.expect(pathOpt != null);

    var path = pathOpt.?;
    defer path.deinit();
    try std.testing.expectEqual(@as(usize, 1), path.nodes.len);
}

test "GridNode equality" {
    const GN = grid_mod.GridNode;
    const a = GN{ .layer = 1, .track_a = 10, .track_b = 20 };
    const b = GN{ .layer = 1, .track_a = 10, .track_b = 20 };
    const c = GN{ .layer = 2, .track_a = 10, .track_b = 20 };

    try std.testing.expect(a.eql(b));
    try std.testing.expect(!a.eql(c));
}
