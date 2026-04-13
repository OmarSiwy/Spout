const std = @import("std");
const core_types = @import("../core/types.zig");
const route_arrays = @import("../core/route_arrays.zig");
const net_arrays = @import("../core/net_arrays.zig");
const pin_edge_arrays = @import("../core/pin_edge_arrays.zig");
const device_arrays = @import("../core/device_arrays.zig");
const adjacency_mod = @import("../core/adjacency.zig");
const layout_if = @import("../core/layout_if.zig");
const grid_mod = @import("grid.zig");
const astar_mod = @import("astar.zig");
const steiner_mod = @import("steiner.zig");
const pin_access_mod = @import("pin_access.zig");
const inline_drc_mod = @import("inline_drc.zig");

const NetIdx = core_types.NetIdx;
const PinIdx = core_types.PinIdx;
const RouteArrays = route_arrays.RouteArrays;
const NetArrays = net_arrays.NetArrays;
const PinEdgeArrays = pin_edge_arrays.PinEdgeArrays;
const DeviceArrays = device_arrays.DeviceArrays;
const FlatAdjList = adjacency_mod.FlatAdjList;
const PdkConfig = layout_if.PdkConfig;
const MultiLayerGrid = grid_mod.MultiLayerGrid;
const GridNode = grid_mod.GridNode;
const AStarRouter = astar_mod.AStarRouter;
const SteinerTree = steiner_mod.SteinerTree;
const PinAccessDB = pin_access_mod.PinAccessDB;
const InlineDrcChecker = inline_drc_mod.InlineDrcChecker;

// ─── Detailed Router ───────────────────────────────────────────────────────
//
// Multi-pin net decomposition using Steiner tree topology, routed on a 3D
// multi-layer grid via A*.  Nets are ordered: power nets first, then
// ascending HPWL, high-fanout nets last.

/// Route layer index convention (matches maze.zig / route_arrays.zig).
const LAYER_M1: u8 = 1;
const LAYER_M2: u8 = 2;

/// Convert a route layer index (1-based for metals) to a PdkConfig array
/// index (0-based from M1).
/// @param route_layer - route layer index (1 = M1, 2 = M2, …)
/// @return 0-based PDK array index
fn pdkIndex(route_layer: u8) usize {
    return @as(usize, route_layer) - 1;
}

/// Per-layer width lookup: returns the PDK minimum width for a grid layer.
/// Grid layer 0 = M1, 1 = M2, etc.
fn layerWidth(pdk: *const PdkConfig, grid_layer: u8) f32 {
    if (grid_layer < pdk.num_metal_layers) return pdk.min_width[grid_layer];
    return pdk.min_width[0]; // fallback
}

/// Net ordering key for routing priority.
const NetOrder = struct {
    net_idx: u32,
    is_power: bool,
    hpwl: f32,
    fanout: u16,
};

/// Compare function for net ordering:
///   1. Power nets first.
///   2. Ascending HPWL (shorter nets first — easier to route).
///   3. High-fanout nets last (they constrain more, route them after simpler nets).
/// @return true if a should be routed before b
fn netOrderLessThan(_: void, a: NetOrder, b: NetOrder) bool {
    // Power nets have highest priority.
    if (a.is_power and !b.is_power) return true;
    if (!a.is_power and b.is_power) return false;

    // Ascending HPWL.
    if (a.hpwl != b.hpwl) return a.hpwl < b.hpwl;

    // Lower fanout first (high fanout = harder = last).
    return a.fanout < b.fanout;
}

/// The detailed router orchestrates grid-based A* routing for all nets.
pub const DetailedRouter = struct {
    allocator: std.mem.Allocator,
    routes: RouteArrays,
    grid: ?MultiLayerGrid,
    drc_checker: ?InlineDrcChecker,

    /// Initialise a DetailedRouter with an empty route set.
    /// @param allocator - memory allocator
    /// @return initialised DetailedRouter
    pub fn init(allocator: std.mem.Allocator) !DetailedRouter {
        return .{
            .allocator = allocator,
            .routes = try RouteArrays.init(allocator, 0),
            .grid = null,
            .drc_checker = null,
        };
    }

    /// Route all nets on a grid using A* search.
    /// @param devices - placed device arrays
    /// @param nets - net property arrays
    /// @param pins - pin position and device arrays
    /// @param adj - pin-to-net adjacency list
    /// @param pdk - PDK design rules
    pub fn routeAll(
        self: *DetailedRouter,
        devices: *const DeviceArrays,
        nets: *const NetArrays,
        pins: *const PinEdgeArrays,
        adj: *const FlatAdjList,
        pdk: *const PdkConfig,
    ) !void {
        // Build the routing grid.
        const margin: f32 = 10.0;
        self.grid = try MultiLayerGrid.init(self.allocator, devices, pdk, margin, pins);

        const grid = &self.grid.?;

        // Build pin access database for DRC-validated routing targets.
        var pin_db = try PinAccessDB.build(self.allocator, devices, pins, grid, pdk);
        defer pin_db.deinit();

        const nNets = nets.len;

        // Build net ordering.
        var order = try self.allocator.alloc(NetOrder, nNets);
        defer self.allocator.free(order);

        for (0..nNets) |i| {
            // Compute HPWL from pin positions.
            const netPins = adj.pinsOnNet(NetIdx.fromInt(@intCast(i)));
            var hpwl: f32 = 0.0;
            if (netPins.len >= 2) {
                var xmin: f32 = std.math.inf(f32);
                var ymin: f32 = std.math.inf(f32);
                var xmax: f32 = -std.math.inf(f32);
                var ymax: f32 = -std.math.inf(f32);
                for (netPins) |pin| {
                    const d = pins.device[pin.toInt()].toInt();
                    if (d >= devices.len) continue;
                    const px = devices.positions[d][0] + pins.position[pin.toInt()][0];
                    const py = devices.positions[d][1] + pins.position[pin.toInt()][1];
                    xmin = @min(xmin, px);
                    ymin = @min(ymin, py);
                    xmax = @max(xmax, px);
                    ymax = @max(ymax, py);
                }
                hpwl = (xmax - xmin) + (ymax - ymin);
            }

            order[i] = .{
                .net_idx = @intCast(i),
                .is_power = nets.is_power[i],
                .hpwl = hpwl,
                .fanout = nets.fanout[i],
            };
        }

        // Sort nets by routing priority.
        std.mem.sort(NetOrder, order, {}, netOrderLessThan);

        // Create inline DRC checker spanning the grid bounding box.
        self.drc_checker = try InlineDrcChecker.init(
            self.allocator,
            pdk,
            grid.bb_xmin,
            grid.bb_ymin,
            grid.bb_xmax,
            grid.bb_ymax,
        );

        // Route each net in priority order.
        var astar = AStarRouter.init(self.allocator);
        astar.drc_checker = if (self.drc_checker != null) &self.drc_checker.? else null;

        var total_failed_edges: u32 = 0;
        for (order) |entry| {
            const netIdx = NetIdx.fromInt(entry.net_idx);
            const netPins = adj.pinsOnNet(netIdx);
            if (netPins.len < 2) continue;

            const failed = try self.routeNet(
                grid,
                &astar,
                devices,
                pins,
                netPins,
                netIdx,
                pdk,
                &pin_db,
            );
            total_failed_edges += failed;
        }

        if (total_failed_edges > 0) {
            std.log.info("detailed router: {d} Steiner edge(s) could not be routed (A* and L-shape fallback both failed)", .{total_failed_edges});
        }
    }

    /// Route a single net using Steiner decomposition + A*.
    /// @param grid - multi-layer routing grid
    /// @param astar - A* router instance
    /// @param devices - device arrays
    /// @param pins - pin arrays
    /// @param net_pins - pins belonging to this net
    /// @param net - net index
    /// @param pdk - PDK configuration for per-layer widths
    /// @param pin_db - pin access database (null = use worldToNode fallback)
    /// @return number of Steiner edges that could not be routed
    fn routeNet(
        self: *DetailedRouter,
        grid: *MultiLayerGrid,
        astar: *const AStarRouter,
        devices: *const DeviceArrays,
        pins: *const PinEdgeArrays,
        net_pins: []const PinIdx,
        net: NetIdx,
        pdk: *const PdkConfig,
        pin_db: ?*const PinAccessDB,
    ) !u32 {
        // Collect absolute pin positions for Steiner tree, and record which
        // global pin index each valid position corresponds to.
        var pinPositions = try self.allocator.alloc([2]f32, net_pins.len);
        defer self.allocator.free(pinPositions);
        var pinIndices = try self.allocator.alloc(u32, net_pins.len);
        defer self.allocator.free(pinIndices);

        var validCount: usize = 0;
        for (net_pins) |pin| {
            const d = pins.device[pin.toInt()].toInt();
            if (d >= devices.len) continue;
            pinPositions[validCount] = .{
                devices.positions[d][0] + pins.position[pin.toInt()][0],
                devices.positions[d][1] + pins.position[pin.toInt()][1],
            };
            pinIndices[validCount] = pin.toInt();
            validCount += 1;
        }

        if (validCount < 2) return 0;
        const positions = pinPositions[0..validCount];
        const indices = pinIndices[0..validCount];

        // Build Steiner tree to decompose multi-pin net into 2-pin segments.
        var tree = try SteinerTree.build(self.allocator, positions);
        defer tree.deinit();

        var failed_edges: u32 = 0;

        // Route each Steiner segment.
        for (tree.segments.items) |seg| {
            if (seg.x1 == seg.x2 and seg.y1 == seg.y2) continue;

            // Resolve endpoints: use PinAccessDB center AP for pin endpoints,
            // fall back to worldToNode for internal Steiner junction points.
            const src = resolveEndpoint(grid, pin_db, positions, indices, seg.x1, seg.y1);
            const tgt = resolveEndpoint(grid, pin_db, positions, indices, seg.x2, seg.y2);

            // Try A* routing first.
            const pathOpt = try astar.findPath(grid, src, tgt, net);
            if (pathOpt) |path_val| {
                var path = path_val;
                defer path.deinit();
                const drc_ptr: ?*InlineDrcChecker = if (self.drc_checker != null) &self.drc_checker.? else null;
                try self.commitPath(grid, &path, net, pdk, drc_ptr);
            } else {
                // Fallback to grid-aware L-shape.
                const m1w = layerWidth(pdk, 0);
                const m2w = layerWidth(pdk, 1);
                const drc_ptr: ?*InlineDrcChecker = if (self.drc_checker != null) &self.drc_checker.? else null;
                try self.emitLShapeGridAware(grid, seg.x1, seg.y1, seg.x2, seg.y2, m1w, m2w, net, drc_ptr);
                failed_edges += 1;
            }
        }

        return failed_edges;
    }

    /// Resolve a Steiner segment endpoint to a GridNode.  If the endpoint
    /// matches a pin position and PinAccessDB has a center AP (cost 0) for
    /// that pin, use it.  Otherwise fall back to worldToNode on layer 0.
    fn resolveEndpoint(
        grid: *MultiLayerGrid,
        pin_db: ?*const PinAccessDB,
        pin_positions: []const [2]f32,
        pin_indices: []const u32,
        wx: f32,
        wy: f32,
    ) GridNode {
        if (pin_db) |db| {
            // Check if this world coordinate matches a pin position.
            for (pin_positions, pin_indices) |pos, pidx| {
                if (pos[0] == wx and pos[1] == wy) {
                    // Found the pin -- look up its center AP (cost 0).
                    if (pidx < db.aps.len) {
                        const aps = db.aps[pidx];
                        // Return the first cost-0 AP (center point).
                        for (aps) |ap| {
                            if (ap.cost == 0.0) return ap.node;
                        }
                        // No cost-0 AP; use lowest-cost AP available.
                        if (aps.len > 0) return aps[0].node;
                    }
                    break;
                }
            }
        }
        // Fallback: internal Steiner junction or no PinAccessDB.
        return grid.worldToNode(0, wx, wy);
    }

    /// Convert an A* path to route segments and claim grid cells.
    /// Also registers segments with the inline DRC checker (if provided)
    /// so subsequent nets see previous routes during A* search.
    /// @param grid - multi-layer routing grid to update cell ownership
    /// @param path - A* path from source to target
    /// @param net - net index
    /// @param pdk - PDK configuration for per-layer widths
    /// @param drc - optional mutable DRC checker for segment registration
    fn commitPath(
        self: *DetailedRouter,
        grid: *MultiLayerGrid,
        path: *const astar_mod.RoutePath,
        net: NetIdx,
        pdk: *const PdkConfig,
        drc: ?*InlineDrcChecker,
    ) !void {
        if (path.nodes.len < 2) return;

        for (path.nodes) |node| {
            grid.claimCell(node, net);
        }

        // Emit segments: merge consecutive same-layer nodes into single segments.
        var segStart: usize = 0;
        var i: usize = 1;
        while (i < path.nodes.len) : (i += 1) {
            const prev = path.nodes[i - 1];
            const curr = path.nodes[i];

            // If layer changes, emit the same-layer run so far, then emit a via.
            if (curr.layer != prev.layer) {
                // Emit horizontal/vertical segment for the run before the via.
                if (i - 1 > segStart) {
                    try self.emitSegment(grid, path.nodes[segStart], prev, net, pdk, drc);
                }
                // Emit via (zero-length segment connecting layers).
                const pos = grid.nodeToWorld(prev);
                const wx = pos[0];
                const wy = pos[1];
                const lowerLayer = @min(prev.layer, curr.layer);
                const viaIdx: usize = @intCast(lowerLayer);
                const viaWidth = if (viaIdx < pdk.num_metal_layers and pdk.via_width[viaIdx] > 0.0)
                    pdk.via_width[viaIdx]
                else
                    @max(layerWidth(pdk, prev.layer), layerWidth(pdk, curr.layer));
                try self.routes.append(lowerLayer + 1, wx, wy, wx, wy, viaWidth, net);
                // Register via with DRC checker.
                if (drc) |d| {
                    try d.addSegment(lowerLayer, wx, wy, wx, wy, viaWidth, net);
                }
                segStart = i;
            } else if (i == path.nodes.len - 1) {
                // End of path: emit final segment.
                try self.emitSegment(grid, path.nodes[segStart], curr, net, pdk, drc);
            }
        }
    }

    /// Emit a route segment between two grid nodes on the same layer.
    /// Also registers the segment with the DRC checker if provided.
    /// @param grid - multi-layer routing grid for coordinate conversion
    /// @param a - start node
    /// @param b - end node
    /// @param net - net index
    /// @param pdk - PDK configuration for per-layer widths
    /// @param drc - optional mutable DRC checker for segment registration
    fn emitSegment(
        self: *DetailedRouter,
        grid: *MultiLayerGrid,
        a: GridNode,
        b: GridNode,
        net: NetIdx,
        pdk: *const PdkConfig,
        drc: ?*InlineDrcChecker,
    ) !void {
        const posA = grid.nodeToWorld(a);
        const posB = grid.nodeToWorld(b);
        const x1 = posA[0];
        const y1 = posA[1];
        const x2 = posB[0];
        const y2 = posB[1];

        // Route layer = grid layer index + 1 (grid layer 0 = M1 = route layer 1).
        const routeLayer: u8 = a.layer + 1;
        const width = layerWidth(pdk, a.layer);

        // For diagonal or non-axis-aligned segments, use grid-aware L-shape
        // routing to avoid DRC violations with pad keepout zones.
        if (x1 != x2 and y1 != y2) {
            const m1w = layerWidth(pdk, 0);
            const m2w = layerWidth(pdk, 1);
            try self.emitLShapeGridAware(grid, x1, y1, x2, y2, m1w, m2w, net, drc);
        } else {
            try self.routes.append(routeLayer, x1, y1, x2, y2, width, net);
            if (drc) |d| {
                // Register with DRC checker using 0-based layer index.
                try d.addSegment(a.layer, x1, y1, x2, y2, width, net);
            }
        }
    }

    /// Fallback: emit an L-shaped route when A* fails.
    /// @param x1 - start x in µm
    /// @param y1 - start y in µm
    /// @param x2 - end x in µm
    /// @param y2 - end y in µm
    /// @param m1w - M1 wire width
    /// @param m2w - M2 wire width
    /// @param net - net index
    fn emitLShape(
        self: *DetailedRouter,
        x1: f32,
        y1: f32,
        x2: f32,
        y2: f32,
        m1w: f32,
        m2w: f32,
        net: NetIdx,
    ) !void {
        if (x1 == x2 and y1 == y2) return;

        if (x1 == x2) {
            // Pure vertical on M2.
            try self.routes.append(LAYER_M2, x1, y1, x2, y2, m2w, net);
        } else if (y1 == y2) {
            // Pure horizontal on M1.
            try self.routes.append(LAYER_M1, x1, y1, x2, y2, m1w, net);
        } else {
            // L-shape: horizontal M1 then vertical M2.
            try self.routes.append(LAYER_M1, x1, y1, x2, y1, m1w, net);
            try self.routes.append(LAYER_M2, x2, y1, x2, y2, m2w, net);
        }
    }

    /// Fallback: emit an L-shaped route entirely on M2 to avoid M1 pad
    /// spacing violations when both M1 and M2 A* searches fail.
    fn emitLShapeM2(
        self: *DetailedRouter,
        x1: f32,
        y1: f32,
        x2: f32,
        y2: f32,
        m2w: f32,
        net: NetIdx,
    ) !void {
        if (x1 == x2 and y1 == y2) return;

        if (x1 != x2 and y1 != y2) {
            try self.routes.append(LAYER_M2, x1, y1, x2, y1, m2w, net);
            try self.routes.append(LAYER_M2, x2, y1, x2, y2, m2w, net);
        } else {
            try self.routes.append(LAYER_M2, x1, y1, x2, y2, m2w, net);
        }
    }

    /// Grid-aware L-shape fallback.  Snaps coordinates to grid cell
    /// centres and checks M1/M2 cells along the path.  Uses M2 for any
    /// segment whose M1 cells are owned by a different net, and claims
    /// cells after routing so later L-shapes don't overlap.
    fn emitLShapeGridAware(
        self: *DetailedRouter,
        grid: *MultiLayerGrid,
        x1: f32,
        y1: f32,
        x2: f32,
        y2: f32,
        m1w: f32,
        m2w: f32,
        net: NetIdx,
        drc: ?*InlineDrcChecker,
    ) !void {
        if (x1 == x2 and y1 == y2) return;

        // Snap to grid cell centres for consistent DRC clearance.
        const node1 = grid.worldToNode(0, x1, y1);
        const node2 = grid.worldToNode(0, x2, y2);
        const pos1 = grid.nodeToWorld(node1);
        const pos2 = grid.nodeToWorld(node2);
        const gx1 = pos1[0];
        const gy1 = pos1[1];
        const gx2 = pos2[0];
        const gy2 = pos2[1];

        if (gx1 == gx2 and gy1 == gy2) return;

        // Check if a horizontal span on M1 (layer 0) is free for this net.
        const isHSpanFree = struct {
            fn check(g: *const MultiLayerGrid, layer: u8, from_x: f32, to_x: f32, at_y: f32, n: NetIdx) bool {
                // Sample cells along the horizontal span.
                const node_a = g.worldToNode(layer, from_x, at_y);
                const node_b = g.worldToNode(layer, to_x, at_y);
                const a_lo = @min(node_a.track_b, node_b.track_b);
                const a_hi = @max(node_a.track_b, node_b.track_b);
                var b: u32 = a_lo;
                while (b <= a_hi) : (b += 1) {
                    const check_node = GridNode{ .layer = layer, .track_a = node_a.track_a, .track_b = b };
                    if (!g.isCellRoutable(check_node, n)) return false;
                }
                return true;
            }
        }.check;

        const m1_gi: u8 = 0; // grid layer for M1
        const m2_gi: u8 = 1; // grid layer for M2

        if (gx1 == gx2) {
            // Pure vertical — always use M2.
            try self.routes.append(LAYER_M2, gx1, gy1, gx2, gy2, m2w, net);
            if (drc) |d| try d.addSegment(m2_gi, gx1, gy1, gx2, gy2, m2w, net);
            self.claimNodeSpan(grid, m2_gi, gx1, gy1, gx1, gy2, net);
        } else if (gy1 == gy2) {
            // Pure horizontal — prefer M1, check for conflicts.
            const use_m1 = isHSpanFree(grid, m1_gi, gx1, gx2, gy1, net);
            const layer: u8 = if (use_m1) m1_gi else m2_gi;
            const rl: u8 = layer + 1;
            const w = if (rl == LAYER_M1) m1w else m2w;
            try self.routes.append(rl, gx1, gy1, gx2, gy2, w, net);
            if (drc) |d| try d.addSegment(layer, gx1, gy1, gx2, gy2, w, net);
            self.claimNodeSpan(grid, layer, gx1, gy1, gx2, gy2, net);
        } else {
            // L-shape: pick layer for horizontal, M2 for vertical.
            const use_m1 = isHSpanFree(grid, m1_gi, gx1, gx2, gy1, net);
            const h_layer: u8 = if (use_m1) m1_gi else m2_gi;
            const h_rl: u8 = h_layer + 1;
            const h_w = if (h_rl == LAYER_M1) m1w else m2w;
            try self.routes.append(h_rl, gx1, gy1, gx2, gy1, h_w, net);
            if (drc) |d| try d.addSegment(h_layer, gx1, gy1, gx2, gy1, h_w, net);
            self.claimNodeSpan(grid, h_layer, gx1, gy1, gx2, gy1, net);

            // Vertical leg always on M2.
            try self.routes.append(LAYER_M2, gx2, gy1, gx2, gy2, m2w, net);
            if (drc) |d| try d.addSegment(m2_gi, gx2, gy1, gx2, gy2, m2w, net);
            self.claimNodeSpan(grid, m2_gi, gx2, gy1, gx2, gy2, net);
        }
    }

    /// Claim cells along a world-coordinate span on a given layer.
    /// Works by snapping endpoints to grid nodes and iterating tracks.
    fn claimNodeSpan(_: *DetailedRouter, grid: *MultiLayerGrid, layer: u8, wx1: f32, wy1: f32, wx2: f32, wy2: f32, net: NetIdx) void {
        const na = grid.worldToNode(layer, wx1, wy1);
        const nb = grid.worldToNode(layer, wx2, wy2);

        const a_lo = @min(na.track_a, nb.track_a);
        const a_hi = @max(na.track_a, nb.track_a);
        const b_lo = @min(na.track_b, nb.track_b);
        const b_hi = @max(na.track_b, nb.track_b);

        var a: u32 = a_lo;
        while (a <= a_hi) : (a += 1) {
            var b: u32 = b_lo;
            while (b <= b_hi) : (b += 1) {
                const node = GridNode{ .layer = layer, .track_a = a, .track_b = b };
                const cell = grid.cellAt(node);
                if (cell.state == .free) {
                    cell.state = .net_owned;
                    cell.net_owner = net;
                }
            }
        }
    }

    /// Rip up all routes belonging to a given net, releasing grid cells
    /// and removing DRC checker segments.
    /// @param net - net index whose routes should be removed
    pub fn ripUpNet(self: *DetailedRouter, net: NetIdx) void {
        // Release grid cells owned by this net (if grid exists).
        if (self.grid) |*grid| {
            for (grid.cells) |*cell| {
                if (cell.state == .net_owned and cell.net_owner.toInt() == net.toInt()) {
                    cell.state = .free;
                    cell.net_owner = NetIdx.fromInt(0);
                }
            }
        }

        // Remove DRC checker segments for this net.
        if (self.drc_checker) |*drc| {
            drc.removeSegmentsForNet(net);
        }

        // Remove route segments belonging to this net from the RouteArrays.
        // We compact in-place.
        var write: u32 = 0;
        const len: usize = @intCast(self.routes.len);
        for (0..len) |read| {
            if (self.routes.net[read].toInt() != net.toInt()) {
                if (write != read) {
                    self.routes.layer[write] = self.routes.layer[read];
                    self.routes.x1[write] = self.routes.x1[read];
                    self.routes.y1[write] = self.routes.y1[read];
                    self.routes.x2[write] = self.routes.x2[read];
                    self.routes.y2[write] = self.routes.y2[read];
                    self.routes.width[write] = self.routes.width[read];
                    self.routes.net[write] = self.routes.net[read];
                }
                write += 1;
            }
        }
        self.routes.len = write;
    }

    /// Return a const pointer to the accumulated route segments.
    /// @return pointer to internal RouteArrays
    pub fn getRoutes(self: *const DetailedRouter) *const RouteArrays {
        return &self.routes;
    }

    /// Free all router resources including the routing grid and DRC checker.
    pub fn deinit(self: *DetailedRouter) void {
        if (self.drc_checker) |*d| d.deinit();
        if (self.grid) |*g| g.deinit();
        self.routes.deinit();
    }
};

// ─── Rip-up and Reroute ────────────────────────────────────────────────────
//
// Post-processing loop that iteratively improves routing quality:
//   1. Score each net by congestion (sum of cell congestion along its path).
//   2. Rip up the worst-scoring net.
//   3. Update congestion map.
//   4. Reroute the net (A* will now be biased away from congested areas).
//   5. Repeat for a fixed number of iterations or until no improvement.

/// Run rip-up and reroute on an already-routed DetailedRouter.
/// `max_iterations` controls the maximum number of RRR passes.
/// Returns the number of iterations actually performed.
/// @param router - already-routed DetailedRouter
/// @param devices - placed device arrays
/// @param nets - net property arrays
/// @param pins - pin position and device arrays
/// @param adj - pin-to-net adjacency list
/// @param pdk - PDK design rules
/// @param max_iterations - maximum number of rip-up-and-reroute passes
/// @return number of iterations performed
pub fn ripUpAndReroute(
    router: *DetailedRouter,
    devices: *const DeviceArrays,
    nets: *const NetArrays,
    pins: *const PinEdgeArrays,
    adj: *const FlatAdjList,
    pdk: *const PdkConfig,
    max_iterations: u32,
) !u32 {
    if (router.grid == null) return 0;

    var astar = AStarRouter.init(router.allocator);
    astar.drc_checker = if (router.drc_checker != null) &router.drc_checker.? else null;
    var iterations: u32 = 0;

    while (iterations < max_iterations) : (iterations += 1) {
        // Score each net by total congestion along its route segments.
        const nNets = nets.len;
        var worstNet: ?u32 = null;
        var worstScore: u16 = 0;

        const grid = &router.grid.?;

        for (0..nNets) |ni| {
            var score: u16 = 0;
            const len: usize = @intCast(router.routes.len);
            for (0..len) |ri| {
                if (router.routes.net[ri].toInt() != @as(u32, @intCast(ni))) continue;
                // Sample congestion at segment endpoints.
                const rl = router.routes.layer[ri];
                if (rl == 0 or rl > grid.num_layers) continue;
                const gridLayer: u8 = rl - 1;
                const node = grid.worldToNode(gridLayer, router.routes.x1[ri], router.routes.y1[ri]);
                score +|= grid.cellAtConst(node).congestion;
            }

            if (score > worstScore) {
                worstScore = score;
                worstNet = @intCast(ni);
            }
        }

        // If no congested net, we're done.
        if (worstNet == null or worstScore <= 1) break;

        const ripNet = NetIdx.fromInt(worstNet.?);
        const netPins = adj.pinsOnNet(ripNet);
        if (netPins.len < 2) continue;

        // Rip up the worst net.
        router.ripUpNet(ripNet);

        // Reroute it (no PinAccessDB in RRR loop — uses worldToNode fallback).
        _ = try router.routeNet(
            grid,
            &astar,
            devices,
            pins,
            netPins,
            ripNet,
            pdk,
            null,
        );
    }

    return iterations;
}

// ─── Tests ──────────────────────────────────────────────────────────────────

test "DetailedRouter init and deinit" {
    var router = try DetailedRouter.init(std.testing.allocator);
    defer router.deinit();

    try std.testing.expectEqual(@as(u32, 0), router.routes.len);
}

test "DetailedRouter emitLShape" {
    var router = try DetailedRouter.init(std.testing.allocator);
    defer router.deinit();

    const net = NetIdx.fromInt(0);
    try router.emitLShape(0.0, 0.0, 5.0, 3.0, 0.14, 0.14, net);

    // Should produce 2 segments (horizontal M1 + vertical M2).
    try std.testing.expectEqual(@as(u32, 2), router.routes.len);
    try std.testing.expectEqual(LAYER_M1, router.routes.layer[0]);
    try std.testing.expectEqual(LAYER_M2, router.routes.layer[1]);
}

test "DetailedRouter emitLShape pure horizontal" {
    var router = try DetailedRouter.init(std.testing.allocator);
    defer router.deinit();

    try router.emitLShape(0.0, 3.0, 5.0, 3.0, 0.14, 0.14, NetIdx.fromInt(1));
    try std.testing.expectEqual(@as(u32, 1), router.routes.len);
    try std.testing.expectEqual(LAYER_M1, router.routes.layer[0]);
}

test "DetailedRouter emitLShape pure vertical" {
    var router = try DetailedRouter.init(std.testing.allocator);
    defer router.deinit();

    try router.emitLShape(2.0, 0.0, 2.0, 5.0, 0.14, 0.14, NetIdx.fromInt(2));
    try std.testing.expectEqual(@as(u32, 1), router.routes.len);
    try std.testing.expectEqual(LAYER_M2, router.routes.layer[0]);
}

test "DetailedRouter ripUpNet" {
    var router = try DetailedRouter.init(std.testing.allocator);
    defer router.deinit();

    const net0 = NetIdx.fromInt(0);
    const net1 = NetIdx.fromInt(1);

    // Add some routes for two nets.
    try router.routes.append(LAYER_M1, 0.0, 0.0, 5.0, 0.0, 0.14, net0);
    try router.routes.append(LAYER_M1, 0.0, 1.0, 5.0, 1.0, 0.14, net1);
    try router.routes.append(LAYER_M2, 5.0, 0.0, 5.0, 1.0, 0.14, net0);

    try std.testing.expectEqual(@as(u32, 3), router.routes.len);

    // Rip up net 0.
    router.ripUpNet(net0);

    // Only net 1's route should remain.
    try std.testing.expectEqual(@as(u32, 1), router.routes.len);
    try std.testing.expectEqual(net1, router.routes.net[0]);
}

test "netOrderLessThan priority" {
    const powerNet = NetOrder{ .net_idx = 0, .is_power = true, .hpwl = 100.0, .fanout = 10 };
    const shortNet = NetOrder{ .net_idx = 1, .is_power = false, .hpwl = 5.0, .fanout = 2 };
    const longNet = NetOrder{ .net_idx = 2, .is_power = false, .hpwl = 50.0, .fanout = 2 };
    const highFan = NetOrder{ .net_idx = 3, .is_power = false, .hpwl = 5.0, .fanout = 20 };

    // Power nets first regardless of HPWL.
    try std.testing.expect(netOrderLessThan({}, powerNet, shortNet));
    try std.testing.expect(!netOrderLessThan({}, shortNet, powerNet));

    // Shorter HPWL first among non-power nets.
    try std.testing.expect(netOrderLessThan({}, shortNet, longNet));

    // Lower fanout first when HPWL is equal.
    try std.testing.expect(netOrderLessThan({}, shortNet, highFan));
}
