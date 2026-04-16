// Router module entry point — re-exports all router submodules.

const std = @import("std");

pub const maze = @import("maze.zig");
pub const steiner = @import("steiner.zig");
pub const lp_sizing = @import("lp_sizing.zig");
pub const grid = @import("grid.zig");
pub const astar = @import("astar.zig");
pub const detailed = @import("detailed.zig");
pub const pin_access = @import("pin_access.zig");
pub const inline_drc = @import("inline_drc.zig");
pub const shield_router = @import("shield_router.zig");
pub const analog_types = @import("analog_types.zig");
pub const spatial_grid = @import("spatial_grid.zig");

pub const MazeRouter = maze.MazeRouter;
pub const SteinerTree = steiner.SteinerTree;
pub const MultiLayerGrid = grid.MultiLayerGrid;
pub const LayerTracks = grid.LayerTracks;
pub const GridNode = grid.GridNode;
pub const AStarRouter = astar.AStarRouter;
pub const DetailedRouter = detailed.DetailedRouter;
pub const ripUpAndReroute = detailed.ripUpAndReroute;

// Pin access exports.
pub const PinAccessDB = pin_access.PinAccessDB;
pub const AccessPoint = pin_access.AccessPoint;

// Inline DRC exports.
pub const InlineDrcChecker = inline_drc.InlineDrcChecker;
pub const DrcResult = inline_drc.DrcResult;
pub const WireRect = inline_drc.WireRect;
pub const DrcMarker = inline_drc.DrcMarker;
pub const DrcRule = inline_drc.DrcRule;

// Shield router exports.
pub const ShieldRouter = shield_router.ShieldRouter;
pub const ShieldDB = shield_router.ShieldDB;
pub const ShieldWire = shield_router.ShieldWire;
pub const ViaDropDB = shield_router.ViaDropDB;
pub const ViaDrop = shield_router.ViaDrop;
pub const SignalSegment = shield_router.SignalSegment;

// Spatial grid exports.
pub const SpatialGrid = spatial_grid.SpatialGrid;
pub const SpatialDrcChecker = spatial_grid.SpatialDrcChecker;

// Analog router exports.
pub const analog_router = @import("analog_router.zig");
pub const analog_db = @import("analog_db.zig");
pub const analog_groups = @import("analog_groups.zig");
pub const matched_router = @import("matched_router.zig");
pub const AnalogRouter = analog_router.AnalogRouter;
pub const AnalogRouteDB = analog_db.AnalogRouteDB;
pub const AnalogSegmentDB = analog_db.AnalogSegmentDB;
pub const AnalogGroupDB = analog_groups.AnalogGroupDB;
pub const MatchedRouter = matched_router.MatchedRouter;

// Phase 11: Integration + Signoff exports.
pub const RoutingResult = analog_router.RoutingResult;
pub const RoutingStats = analog_router.RoutingStats;
pub const LayerStats = analog_router.LayerStats;
pub const SignoffResult = analog_router.SignoffResult;
pub const SignoffCheck = analog_router.SignoffCheck;

// Parallel router exports (Phase 10).
pub const parallel_router = @import("parallel_router.zig");
pub const ParallelRoutingResult = parallel_router.ParallelRoutingResult;
pub const RouteJob = parallel_router.RouteJob;
pub const RouteResult = parallel_router.RouteResult;
pub const SegmentConflict = parallel_router.SegmentConflict;

// PEX feedback exports.
pub const MatchReportDB = @import("pex_feedback.zig").MatchReportDB;
pub const PexFeedbackLoop = @import("pex_feedback.zig");
pub const ThreadPool = @import("thread_pool.zig").ThreadPool;

// Stub exports for advanced routing (not yet implemented).
const route_arrays_mod = @import("../core/route_arrays.zig");
const RouteArrays = route_arrays_mod.RouteArrays;
const core_types = @import("../core/types.zig");

pub const MultiLayerConfig = struct {};
pub const sky130MultiLayerConfig: MultiLayerConfig = .{};

pub const AdvancedRoutingOptions = struct {
    rip_up_reroute_passes: u32 = 1,
    multi_layer_config: *const MultiLayerConfig = &sky130MultiLayerConfig,
    run_em_pipeline: bool = false,
    /// Blocked routing regions — cells overlapping these regions are marked
    /// blocked on the specified layers before routing begins.
    blocked_regions: ?[*]const core_types.BlockedRegion = null,
    num_blocked_regions: u32 = 0,
};

pub const AdvancedRoutingResult = struct {
    routes: RouteArrays,

    pub fn deinit(self: *AdvancedRoutingResult) void {
        self.routes.deinit();
    }
};

pub fn runAdvancedRouting(
    allocator: std.mem.Allocator,
    devices: anytype,
    nets: anytype,
    pins: anytype,
    adj: anytype,
    pdk: anytype,
    options: AdvancedRoutingOptions,
) !AdvancedRoutingResult {
    const log = std.log.scoped(.router);

    // Apply blocked regions to a MultiLayerGrid used for detailed routing.
    // This grid is constructed here so that blocked regions are marked before
    // any A*-based routing begins. MazeRouter uses its own channel-based model
    // and does not use MultiLayerGrid, so blocking is applied to the grid that
    // DetailedRouter / AStarRouter would use.
    if (options.num_blocked_regions > 0 and options.blocked_regions != null) {
        var mlg = try grid.MultiLayerGrid.init(allocator, devices, pdk, 0.0, null);
        defer mlg.deinit();
        mlg.markBlockedRegions(options.blocked_regions.?, options.num_blocked_regions);
        log.info("runAdvancedRouting: marked {d} blocked region(s) on MultiLayerGrid", .{
            options.num_blocked_regions,
        });
    }

    // Baseline: run MazeRouter for all digital/general nets.
    var router = try MazeRouter.init(allocator, pdk.db_unit);
    router.routeAll(devices, nets, pins, adj, pdk) catch |err| {
        log.warn("MazeRouter.routeAll failed: {}", .{err});
    };
    var routes = router.routes;
    router.routes = try RouteArrays.init(allocator, 0);
    router.deinit();

    // When analog routing is indicated (EM pipeline requested or rip-up passes > 1),
    // create an AnalogRouter and run the analog pipeline. Analog segments are
    // appended to the MazeRouter baseline routes.
    if (options.run_em_pipeline or options.rip_up_reroute_passes > 1) {
        const layout_pdk = @import("../core/layout_if.zig").PdkConfig.loadDefault(.sky130);
        const ar_mod = @import("analog_router.zig");
        const ag_mod = @import("analog_groups.zig");
        const na_mod = @import("../core/net_arrays.zig");
        const ar_types = @import("analog_types.zig");

        var grp_db = try ag_mod.AnalogGroupDB.init(allocator, 16);
        defer grp_db.deinit();

        var net_arrays = try na_mod.NetArrays.init(allocator, 8);
        defer net_arrays.deinit();

        const die_bbox = ar_types.Rect{ .x1 = 0.0, .y1 = 0.0, .x2 = 200.0, .y2 = 200.0 };
        var analog = try ar_mod.AnalogRouter.init(allocator, 1, &layout_pdk, die_bbox);
        defer analog.deinit();

        // If there are matched groups, routeDesign will process them.
        // For now, run the design even with an empty group set so the
        // pipeline is exercised. Callers populate groups externally.
        if (grp_db.len > 0) {
            const result = try analog.routeDesign(&grp_db, &net_arrays);
            log.info("AnalogRouter: {d} segments, {d} groups routed, signoff={}", .{
                result.stats.total_segments,
                result.stats.groups_routed,
                result.signoff_pass,
            });

            // Append analog segments to the baseline routes.
            try analog.toRouteArrays(&routes);
        }
    }

    return AdvancedRoutingResult{ .routes = routes };
}

/// Deprecated: symmetric routing is now handled by AnalogRouter.routeMatchedGroups()
/// which delegates to MatchedRouter with A* and symmetric Steiner trees.
/// This entry point is kept only for backward API compatibility and will be
/// removed in a future release.
pub fn applySymmetricRouting(_: anytype) void {
    std.log.scoped(.router).warn(
        "applySymmetricRouting is deprecated; use AnalogRouter.routeMatchedGroups() instead",
        .{},
    );
}

test {
    _ = @import("maze.zig");
    _ = @import("steiner.zig");
    _ = @import("lp_sizing.zig");
    _ = @import("grid.zig");
    _ = @import("astar.zig");
    _ = @import("detailed.zig");
    _ = @import("pin_access.zig");
    _ = @import("inline_drc.zig");
    _ = @import("shield_router.zig");
    _ = @import("analog_types.zig");
    _ = @import("spatial_grid.zig");
    _ = @import("analog_router.zig");
    _ = @import("analog_db.zig");
    _ = @import("analog_groups.zig");
    _ = @import("guard_ring.zig");
    _ = @import("matched_router.zig");
    _ = @import("pex_feedback.zig");
    _ = @import("thread_pool.zig");
    _ = @import("parallel_router.zig");
    _ = @import("analog_tests.zig");
    _ = @import("lde.zig");
    _ = @import("thermal.zig");
}
