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
    _ = options;
    // Delegate to MazeRouter for now.
    var router = try MazeRouter.init(allocator, pdk.db_unit);
    router.routeAll(devices, nets, pins, adj, pdk) catch {};
    const routes = router.routes;
    router.routes = try RouteArrays.init(allocator, 0);
    router.deinit();
    return AdvancedRoutingResult{ .routes = routes };
}

pub fn applySymmetricRouting(_: anytype) void {}

test {
    _ = @import("maze.zig");
    _ = @import("steiner.zig");
    _ = @import("lp_sizing.zig");
    _ = @import("grid.zig");
    _ = @import("astar.zig");
    _ = @import("detailed.zig");
    _ = @import("pin_access.zig");
    _ = @import("inline_drc.zig");
}
