// Core module entry point — re-exports all core submodules.

pub const types = @import("types.zig");
pub const device_arrays = @import("device_arrays.zig");
pub const net_arrays = @import("net_arrays.zig");
pub const pin_edge_arrays = @import("pin_edge_arrays.zig");
pub const constraint_arrays = @import("constraint_arrays.zig");
pub const route_arrays = @import("route_arrays.zig");
pub const shape_arrays = @import("shape_arrays.zig");
pub const adjacency = @import("adjacency.zig");
pub const layout_if = @import("layout_if.zig");

// Re-export key types
pub const DeviceIdx = types.DeviceIdx;
pub const NetIdx = types.NetIdx;
pub const PinIdx = types.PinIdx;
pub const LayerIdx = types.LayerIdx;
pub const DeviceType = types.DeviceType;
pub const TerminalType = types.TerminalType;
pub const DeviceParams = types.DeviceParams;
pub const ConstraintType = types.ConstraintType;
pub const DrcRule = types.DrcRule;
pub const DrcMetric = types.DrcMetric;
pub const DrcViolation = types.DrcViolation;
pub const PdkId = types.PdkId;

pub const DeviceArrays = device_arrays.DeviceArrays;
pub const NetArrays = net_arrays.NetArrays;
pub const PinEdgeArrays = pin_edge_arrays.PinEdgeArrays;
pub const ConstraintArrays = constraint_arrays.ConstraintArrays;
pub const RouteArrays = route_arrays.RouteArrays;
pub const ShapeArrays = shape_arrays.ShapeArrays;
pub const FlatAdjList = adjacency.FlatAdjList;
pub const PdkConfig = layout_if.PdkConfig;

test {
    _ = @import("types.zig");
    _ = @import("device_arrays.zig");
    _ = @import("net_arrays.zig");
    _ = @import("pin_edge_arrays.zig");
    _ = @import("constraint_arrays.zig");
    _ = @import("route_arrays.zig");
    _ = @import("shape_arrays.zig");
    _ = @import("adjacency.zig");
    _ = @import("layout_if.zig");
}
