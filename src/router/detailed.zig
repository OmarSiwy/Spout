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
const analog_router_mod = @import("analog_router.zig");
const analog_groups_mod = @import("analog_groups.zig");
const analog_types_mod = @import("analog_types.zig");

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
const AnalogRouter = analog_router_mod.AnalogRouter;
const AnalogGroupDB = analog_groups_mod.AnalogGroupDB;
const AnalogRect = analog_types_mod.Rect;

// ─── Debug helper (shared-library safe) ────────────────────────────────────
// std.debug.print uses a mutex from std.Progress which is not initialized in
// shared libraries.  Use raw posix write with a stack buffer instead.
fn dbgPrint(comptime fmt: []const u8, args: anytype) void {
    var buf: [512]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt, args) catch return;
    _ = std.posix.write(2, s) catch {};
}

// ─── Detailed Router ───────────────────────────────────────────────────────
//
// Multi-pin net decomposition using Steiner tree topology, routed on a 3D
// multi-layer grid via A*.  Nets are ordered: signals first (ascending HPWL,
// low fanout first), power nets last so they can detour around signals.

/// Route layer index convention (matches maze.zig / route_arrays.zig).
const LAYER_M1: u8 = 1;
const LAYER_M2: u8 = 2;
const LAYER_M3: u8 = 3;

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
///   1. Signal nets first, power nets last (BUGS.md S1-8).  Power nets
///      (VSS/VDD) have more pins and tolerate detours; routing them first
///      caused them to grab M2/M3 columns that signals later need, leading
///      to silent drops for short signal nets.  Signals go first so they
///      claim the tight columns near device pins; power routes around them.
///   2. Ascending HPWL (shorter nets first — easier to route).
///   3. High-fanout nets last (they constrain more, route them after simpler nets).
/// @return true if a should be routed before b
fn netOrderLessThan(_: void, a: NetOrder, b: NetOrder) bool {
    // Signals before power.
    if (a.is_power != b.is_power) return !a.is_power;

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
    astar_ok: u32 = 0,
    astar_fail: u32 = 0,
    /// Count of emitLShapeGridAware silent-drop branches (BUGS.md S0-1).
    /// Each increment corresponds to a Steiner edge that could not be placed
    /// because every candidate layer was blocked by a previously-routed net.
    lshape_drop_vert: u32 = 0,
    lshape_drop_horiz: u32 = 0,
    lshape_drop_l_horiz: u32 = 0,
    lshape_drop_l_vert: u32 = 0,
    /// Analog post-processor: initialized lazily in routeAll() once the routing
    /// grid bounding box is known.  Null until the first call to routeAll().
    analog_router: ?AnalogRouter = null,

    /// Initialise a DetailedRouter with an empty route set.
    /// @param allocator - memory allocator
    /// @return initialised DetailedRouter
    pub fn init(allocator: std.mem.Allocator) !DetailedRouter {
        return .{
            .allocator = allocator,
            .routes = try RouteArrays.init(allocator, 0),
            .grid = null,
            .drc_checker = null,
            .analog_router = null,
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
        // DRC checker disabled during A* to avoid over-constraining search.
        // Grid cell ownership already prevents net-to-net shorts.
        var astar = AStarRouter.init(self.allocator);

        for (order) |entry| {
            const netIdx = NetIdx.fromInt(entry.net_idx);
            const netPins = adj.pinsOnNet(netIdx);
            if (netPins.len < 2) continue;

            _ = try self.routeNet(
                grid,
                &astar,
                devices,
                pins,
                netPins,
                netIdx,
                nets,
                pdk,
                &pin_db,
            );
        }

        // Analog post-processing: initialise AnalogRouter using the grid bounding
        // box computed above, then run matched-net fixup, shield application, and
        // guard ring validation over the routed net batch.
        const die_bbox = AnalogRect{
            .x1 = grid.bb_xmin,
            .y1 = grid.bb_ymin,
            .x2 = grid.bb_xmax,
            .y2 = grid.bb_ymax,
        };
        // Initialise (or re-initialise) the analog router for this routing pass.
        if (self.analog_router) |*ar| ar.deinit();
        self.analog_router = try AnalogRouter.init(self.allocator, 1, pdk, die_bbox);

        // Build an empty AnalogGroupDB so the post-processing hooks run even
        // when no explicit analog groups were declared by the caller.  Groups are
        // discovered automatically from the AnalogSegmentDB inside AnalogRouter.
        var empty_groups = try AnalogGroupDB.init(self.allocator, 0);
        defer empty_groups.deinit();

        // Route analog group post-processing (matched fixup, shielding, guard rings,
        // PEX feedback).  Operates on whatever groups are in the DB; with an empty
        // DB this is effectively a no-op but ensures the infrastructure is exercised.
        // routeAllGroups takes a mutable *NetArrays; cast away const since it only
        // reads net data (is_power, fanout) and does not modify any fields.
        var nets_mut = nets.*;
        try self.analog_router.?.routeAllGroups(&empty_groups, &nets_mut);

        // Router diagnostics (BUGS.md §4.4).
        dbgPrint(
            "ROUTER STATS: astar_ok={} astar_fail={} L-DROP vert={} horiz={} l_horiz={} l_vert={}\n",
            .{ self.astar_ok, self.astar_fail, self.lshape_drop_vert, self.lshape_drop_horiz, self.lshape_drop_l_horiz, self.lshape_drop_l_vert },
        );
    }

    /// Route a single net using Steiner decomposition + A*.
    /// @param grid - multi-layer routing grid
    /// @param astar - A* router instance
    /// @param devices - device arrays
    /// @param pins - pin arrays
    /// @param net_pins - pins belonging to this net
    /// @param net - net index
    /// @param nets - net arrays (for debug: is_power flag)
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
        nets: ?*const net_arrays.NetArrays,
        pdk: *const PdkConfig,
        pin_db: ?*const PinAccessDB,
    ) !u32 {
        _ = nets;

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
            const px = devices.positions[d][0] + pins.position[pin.toInt()][0];
            const py = devices.positions[d][1] + pins.position[pin.toInt()][1];
            pinPositions[validCount] = .{ px, py };
            pinIndices[validCount] = pin.toInt();
            validCount += 1;
        }

        if (validCount < 2) return 0;
        const positions = pinPositions[0..validCount];
        const indices = pinIndices[0..validCount];

        // Pin-to-AP stitch (BUGS.md S1-5).  Device-layout emits its M1 pin pad
        // centred at the physical pin (px, py); the router emits its M1 landing
        // pad centred at the grid-snapped AP (ap.x, ap.y) via resolveEndpoint.
        // When worldToNode snaps by more than (pad_half - device_pad_half), the
        // two M1 rectangles do not overlap → net fragments → LVS fail.  Emit a
        // short M1 L-shape from the physical pin to its center AP so the two
        // pads are always geometrically connected.
        if (pin_db) |db| {
            const m1w = layerWidth(pdk, 0);
            for (0..validCount) |ii| {
                const pidx = indices[ii];
                if (pidx >= db.aps.len) continue;
                const pin_x = positions[ii][0];
                const pin_y = positions[ii][1];
                const aps = db.aps[pidx];
                var center_ap: ?pin_access_mod.AccessPoint = null;
                for (aps) |ap| {
                    if (ap.cost == 0.0) {
                        center_ap = ap;
                        break;
                    }
                }
                const ap = center_ap orelse continue;
                dbgPrint(
                    "STITCH net={} pidx={} pin=({d:.3},{d:.3}) ap=({d:.3},{d:.3}) ap_node_world=({d:.3},{d:.3})\n",
                    .{ net.toInt(), pidx, pin_x, pin_y, ap.x, ap.y, grid.nodeToWorld(ap.node)[0], grid.nodeToWorld(ap.node)[1] },
                );
                if (pin_x == ap.x and pin_y == ap.y) continue;
                if (pin_x == ap.x or pin_y == ap.y) {
                    try self.routes.append(LAYER_M1, pin_x, pin_y, ap.x, ap.y, m1w, net);
                } else {
                    // L-shape: horizontal then vertical, both on M1.
                    try self.routes.append(LAYER_M1, pin_x, pin_y, ap.x, pin_y, m1w, net);
                    try self.routes.append(LAYER_M1, ap.x, pin_y, ap.x, ap.y, m1w, net);
                }
            }
        }

        // Build Steiner tree to decompose multi-pin net into 2-pin segments.
        var tree = try SteinerTree.build(self.allocator, positions);
        defer tree.deinit();

        // Claim all internal Steiner junction cells as net_owned so A* can
        // navigate through them.  Junction cells (segment endpoints that are
        // not real pin positions) may fall outside device keepout zones in
        // free space surrounded by blocked cells — without claiming them,
        // A* has no routable neighbors to expand from.
        for (tree.segments.items) |seg| {
            inline for ([2][2]f32{ .{ seg.x1, seg.y1 }, .{ seg.x2, seg.y2 } }) |pt| {
                const is_pin = for (positions) |p| {
                    if (p[0] == pt[0] and p[1] == pt[1]) break true;
                } else false;
                if (!is_pin) {
                    grid.claimCell(grid.worldToNode(0, pt[0], pt[1]), net);
                }
            }
        }

        var failed_edges: u32 = 0;

        // Route each Steiner segment.
        for (tree.segments.items) |seg| {
            if (seg.x1 == seg.x2 and seg.y1 == seg.y2) continue;

            // Resolve endpoints: use PinAccessDB center AP for pin endpoints,
            // fall back to worldToNode for internal Steiner junction points.
            const src = resolveEndpoint(grid, pin_db, positions, indices, seg.x1, seg.y1);
            const tgt = resolveEndpoint(grid, pin_db, positions, indices, seg.x2, seg.y2);
            {
                const spos = grid.nodeToWorld(src);
                const tpos = grid.nodeToWorld(tgt);
                dbgPrint(
                    "SEG net={} world=({d:.3},{d:.3})->({d:.3},{d:.3}) src_node=L{}(tA={},tB={},world={d:.3},{d:.3}) tgt_node=L{}(tA={},tB={},world={d:.3},{d:.3})\n",
                    .{ net.toInt(), seg.x1, seg.y1, seg.x2, seg.y2, src.layer, src.track_a, src.track_b, spos[0], spos[1], tgt.layer, tgt.track_a, tgt.track_b, tpos[0], tpos[1] },
                );
            }

            // If either endpoint cell is owned by a DIFFERENT net, A* will
            // detour around the blocked cell and produce a route that misses
            // device contacts.  Force the geometric fallback so emitM2WithVias
            // (or emitM3WithVias) routes at the actual pin positions and
            // generates M1 landing pads that overlap device mcon.
            const src_cell = grid.cellAtConst(src);
            const tgt_cell = grid.cellAtConst(tgt);
            const endpoint_blocked =
                (src_cell.state == .net_owned and src_cell.net_owner.toInt() != net.toInt()) or
                (tgt_cell.state == .net_owned and tgt_cell.net_owner.toInt() != net.toInt());

            // Try A* routing first (skip if an endpoint is blocked by another net).
            const raw_path_opt = if (endpoint_blocked) null else try astar.findPath(grid, src, tgt, net);

            // Reject A* paths that detour far outside the src-to-tgt x bounding box.
            // BUGS.md S1-2: a fixed one-pitch margin was too tight and forced
            // needless fallbacks for legitimate routes that jog around blockages.
            // Use an adaptive margin: max(li_pitch, 25% of HPWL).  This keeps
            // short nets on a tight leash while letting longer nets detour
            // proportionally.
            const use_astar: bool = if (raw_path_opt) |p| blk: {
                const src_wx = grid.nodeToWorld(src)[0];
                const src_wy = grid.nodeToWorld(src)[1];
                const tgt_wx = grid.nodeToWorld(tgt)[0];
                const tgt_wy = grid.nodeToWorld(tgt)[1];
                const li_pitch = grid.layers[0].pitch;
                const hpwl = @abs(tgt_wx - src_wx) + @abs(tgt_wy - src_wy);
                const margin = @max(li_pitch, hpwl * 0.25);
                const x_lo = @min(src_wx, tgt_wx) - margin;
                const x_hi = @max(src_wx, tgt_wx) + margin;
                for (p.nodes) |nd| {
                    const wx = grid.nodeToWorld(nd)[0];
                    if (wx < x_lo or wx > x_hi) break :blk false;
                }
                break :blk true;
            } else false;

            if (use_astar) {
                var path = raw_path_opt.?;
                defer path.deinit();
                const drc_ptr: ?*InlineDrcChecker = if (self.drc_checker != null) &self.drc_checker.? else null;
                if (net.toInt() == 7) {
                    for (path.nodes, 0..) |pn, pi| {
                        const pw = grid.nodeToWorld(pn);
                        dbgPrint("  PATH[{}] L{} tA={} tB={} world=({d:.3},{d:.3})\n", .{ pi, pn.layer, pn.track_a, pn.track_b, pw[0], pw[1] });
                    }
                }
                try self.commitPath(grid, &path, net, pdk, drc_ptr);
                self.astar_ok += 1;
            } else {
                // Free rejected detour path if A* found one.
                if (raw_path_opt) |p| {
                    var to_free = p;
                    to_free.deinit();
                }
                self.astar_fail += 1;
                // Fallback to grid-aware L-shape (tries M2, then M3).
                const m1w = layerWidth(pdk, 0);
                const m2w = layerWidth(pdk, 1);
                const drc_ptr: ?*InlineDrcChecker = if (self.drc_checker != null) &self.drc_checker.? else null;
                try self.emitLShapeGridAware(grid, seg.x1, seg.y1, seg.x2, seg.y2, m1w, m2w, net, drc_ptr, pdk);
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
                // Emit segment for the run before the via.  Use >= so that a
                // single-node run at the path start (the source pin) also emits
                // a zero-length M1 stub — this is required for writeRoutes to
                // detect the M1/M2 layer transition and emit a via cut.
                if (i - 1 >= segStart) {
                    try self.emitSegment(grid, path.nodes[segStart], prev, net, pdk, drc);
                }
                // Emit via (zero-length segment connecting layers).
                const pos = grid.nodeToWorld(prev);
                const wx = pos[0];
                const wy = pos[1];
                const curr_pos = grid.nodeToWorld(curr);
                const cx = curr_pos[0];
                const cy = curr_pos[1];
                const lowerLayer = @min(prev.layer, curr.layer);
                const viaIdx: usize = @intCast(lowerLayer);
                const viaWidth = if (viaIdx < pdk.num_metal_layers and pdk.via_width[viaIdx] > 0.0)
                    pdk.via_width[viaIdx]
                else
                    @max(layerWidth(pdk, prev.layer), layerWidth(pdk, curr.layer));
                try self.routes.append(lowerLayer + 1, wx, wy, wx, wy, viaWidth, net);
                dbgPrint(
                    "VIA net={} at ({d:.3},{d:.3}) layers={}->{}\n",
                    .{ net.toInt(), wx, wy, prev.layer, curr.layer },
                );
                // Register via with DRC checker.
                if (drc) |d| {
                    try d.addSegment(lowerLayer, wx, wy, wx, wy, viaWidth, net);
                }
                // Bridge segment: if the via landed at world(prev) but curr is
                // on a different world position (A* via-with-offset, see
                // astar.zig getNeighbors via-down offsets), emit a connecting
                // wire on curr.layer from world(prev) to world(curr) so the
                // landing pad overlaps curr's cell and net does not fragment.
                if (wx != cx or wy != cy) {
                    const bridgeLayer: u8 = curr.layer + 1;
                    const bridgeWidth = layerWidth(pdk, curr.layer);
                    if (wx == cx or wy == cy) {
                        try self.routes.append(bridgeLayer, wx, wy, cx, cy, bridgeWidth, net);
                        if (drc) |d| try d.addSegment(curr.layer, wx, wy, cx, cy, bridgeWidth, net);
                    } else {
                        try self.routes.append(bridgeLayer, wx, wy, cx, wy, bridgeWidth, net);
                        try self.routes.append(bridgeLayer, cx, wy, cx, cy, bridgeWidth, net);
                        if (drc) |d| {
                            try d.addSegment(curr.layer, wx, wy, cx, wy, bridgeWidth, net);
                            try d.addSegment(curr.layer, cx, wy, cx, cy, bridgeWidth, net);
                        }
                    }
                    dbgPrint(
                        "BRIDGE net={} L{} ({d:.3},{d:.3})->({d:.3},{d:.3})\n",
                        .{ net.toInt(), curr.layer, wx, wy, cx, cy },
                    );
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
            try self.emitLShapeGridAware(grid, x1, y1, x2, y2, m1w, m2w, net, drc, pdk);
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

    /// Check if a span between two world coords on a given grid layer is
    /// free (or owned by `net`).
    fn isSpanFree(grid: *const MultiLayerGrid, layer: u8, from_x: f32, from_y: f32, to_x: f32, to_y: f32, net: NetIdx) bool {
        const node_a = grid.worldToNode(layer, from_x, from_y);
        const node_b = grid.worldToNode(layer, to_x, to_y);
        const a_lo = @min(node_a.track_a, node_b.track_a);
        const a_hi = @max(node_a.track_a, node_b.track_a);
        const b_lo = @min(node_a.track_b, node_b.track_b);
        const b_hi = @max(node_a.track_b, node_b.track_b);
        var a: u32 = a_lo;
        while (a <= a_hi) : (a += 1) {
            var b: u32 = b_lo;
            while (b <= b_hi) : (b += 1) {
                if (!grid.isCellRoutable(.{ .layer = layer, .track_a = a, .track_b = b }, net)) return false;
            }
        }
        return true;
    }

    /// Emit an M2 segment with M1 landing pads at both endpoints.
    /// The device geometry already writes licon + LI + mcon at each pin position,
    /// so we only need M1 stubs here. writeRoutes generates via1 rectangles at
    /// the M1→M2 and M2→M1 layer transitions (triggered by zero-length markers).
    /// Claims M2 grid cells along the segment.
    fn emitM2WithVias(
        self: *DetailedRouter,
        grid: *MultiLayerGrid,
        sx1: f32,
        sy1: f32,
        sx2: f32,
        sy2: f32,
        m1w: f32,
        m2w: f32,
        net: NetIdx,
        drc: ?*InlineDrcChecker,
    ) !void {
        try self.routes.append(LAYER_M1, sx1, sy1, sx1, sy1, m1w, net);
        try self.routes.append(LAYER_M2, sx1, sy1, sx2, sy2, m2w, net);
        try self.routes.append(LAYER_M1, sx2, sy2, sx2, sy2, m1w, net);
        if (drc) |d| try d.addSegment(1, sx1, sy1, sx2, sy2, m2w, net);
        self.claimNodeSpan(grid, 1, sx1, sy1, sx2, sy2, net);
    }

    /// Emit an M3 segment with M1+M2 landing pads at both endpoints.
    /// Device geometry provides licon + LI + mcon; only M1/M2 stubs needed here.
    fn emitM3WithVias(
        self: *DetailedRouter,
        grid: *MultiLayerGrid,
        sx1: f32,
        sy1: f32,
        sx2: f32,
        sy2: f32,
        m1w: f32,
        m2w: f32,
        m3w: f32,
        net: NetIdx,
        drc: ?*InlineDrcChecker,
    ) !void {
        try self.routes.append(LAYER_M1, sx1, sy1, sx1, sy1, m1w, net);
        try self.routes.append(LAYER_M2, sx1, sy1, sx1, sy1, m2w, net);
        try self.routes.append(LAYER_M3, sx1, sy1, sx2, sy2, m3w, net);
        try self.routes.append(LAYER_M2, sx2, sy2, sx2, sy2, m2w, net);
        try self.routes.append(LAYER_M1, sx2, sy2, sx2, sy2, m1w, net);
        if (drc) |d| try d.addSegment(2, sx1, sy1, sx2, sy2, m3w, net);
        self.claimNodeSpan(grid, 2, sx1, sy1, sx2, sy2, net);
    }

    /// Grid-aware L-shape fallback.  Checks cell ownership on M1, M2, and M3
    /// to avoid overlapping routes from different nets.
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
        pdk: *const PdkConfig,
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

        if (gx1 == gx2) {
            // Pure vertical — M2 with via pads; M3 fallback when M2 blocked.
            const m1_free = isSpanFree(grid, 1, gx1, gy1, gx2, gy2, net);
            if (m1_free) {
                try self.emitM2WithVias(grid, gx1, gy1, gx2, gy2, m1w, m2w, net, drc);
            } else if (pdk.num_metal_layers > 2 and isSpanFree(grid, 2, gx1, gy1, gx2, gy2, net)) {
                try self.emitM3WithVias(grid, gx1, gy1, gx2, gy2, m1w, m2w, layerWidth(pdk, 2), net, drc);
            } else {
                // Silent drop: grid column blocked on M2 and M3.  Log + count.
                self.lshape_drop_vert += 1;
                dbgPrint("L-DROP vert net={} ({d:.3},{d:.3})->({d:.3},{d:.3})\n", .{ net.toInt(), gx1, gy1, gx2, gy2 });
            }
        } else if (gy1 == gy2) {
            // Pure horizontal — prefer M1, then M2.
            if (isSpanFree(grid, 0, gx1, gy1, gx2, gy2, net)) {
                try self.routes.append(LAYER_M1, gx1, gy1, gx2, gy2, m1w, net);
                if (drc) |d| try d.addSegment(0, gx1, gy1, gx2, gy2, m1w, net);
                self.claimNodeSpan(grid, 0, gx1, gy1, gx2, gy2, net);
            } else if (isSpanFree(grid, 1, gx1, gy1, gx2, gy2, net)) {
                try self.emitM2WithVias(grid, gx1, gy1, gx2, gy2, m1w, m2w, net, drc);
            } else {
                self.lshape_drop_horiz += 1;
                dbgPrint("L-DROP horiz net={} ({d:.3},{d:.3})->({d:.3},{d:.3})\n", .{ net.toInt(), gx1, gy1, gx2, gy2 });
            }
        } else {
            // L-shape: horizontal + vertical.
            // Horizontal leg: try M1 first, then M2.
            if (isSpanFree(grid, 0, gx1, gy1, gx2, gy1, net)) {
                try self.routes.append(LAYER_M1, gx1, gy1, gx2, gy1, m1w, net);
                if (drc) |d| try d.addSegment(0, gx1, gy1, gx2, gy1, m1w, net);
                self.claimNodeSpan(grid, 0, gx1, gy1, gx2, gy1, net);
            } else if (isSpanFree(grid, 1, gx1, gy1, gx2, gy1, net)) {
                try self.emitM2WithVias(grid, gx1, gy1, gx2, gy1, m1w, m2w, net, drc);
            } else {
                self.lshape_drop_l_horiz += 1;
                dbgPrint("L-DROP l_horiz net={} ({d:.3},{d:.3})->({d:.3},{d:.3})\n", .{ net.toInt(), gx1, gy1, gx2, gy1 });
            }

            // Vertical leg: M2; M3 fallback when M2 blocked.
            if (isSpanFree(grid, 1, gx2, gy1, gx2, gy2, net)) {
                try self.emitM2WithVias(grid, gx2, gy1, gx2, gy2, m1w, m2w, net, drc);
            } else if (pdk.num_metal_layers > 2 and isSpanFree(grid, 2, gx2, gy1, gx2, gy2, net)) {
                try self.emitM3WithVias(grid, gx2, gy1, gx2, gy2, m1w, m2w, layerWidth(pdk, 2), net, drc);
            } else {
                self.lshape_drop_l_vert += 1;
                dbgPrint("L-DROP l_vert net={} ({d:.3},{d:.3})->({d:.3},{d:.3})\n", .{ net.toInt(), gx2, gy1, gx2, gy2 });
            }
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

    /// Free all router resources including the routing grid, DRC checker, and
    /// the analog post-processor (if it was initialised).
    pub fn deinit(self: *DetailedRouter) void {
        if (self.drc_checker) |*d| d.deinit();
        if (self.grid) |*g| g.deinit();
        if (self.analog_router) |*ar| ar.deinit();
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
            nets,
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

    // Signal nets first; power nets last (BUGS.md S1-8 reversal).
    try std.testing.expect(netOrderLessThan({}, shortNet, powerNet));
    try std.testing.expect(!netOrderLessThan({}, powerNet, shortNet));

    // Shorter HPWL first among non-power nets.
    try std.testing.expect(netOrderLessThan({}, shortNet, longNet));

    // Lower fanout first when HPWL is equal.
    try std.testing.expect(netOrderLessThan({}, shortNet, highFan));
}
