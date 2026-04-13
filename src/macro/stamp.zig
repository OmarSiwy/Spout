const std = @import("std");
const device_arrays_mod = @import("../core/device_arrays.zig");
const core_types = @import("../core/types.zig");
const pin_edge_arrays_mod = @import("../core/pin_edge_arrays.zig");
const adjacency_mod = @import("../core/adjacency.zig");
const types_mod = @import("types.zig");
const detect_mod = @import("detect.zig");

const MacroArrays = types_mod.MacroArrays;
const MacroTemplate = types_mod.MacroTemplate;
const DeviceIdx = core_types.DeviceIdx;
const NetIdx = core_types.NetIdx;

/// Compute [width, height] bounding box of a template's unit cell.
/// `positions` and `dimensions` are provided separately so callers can
/// pass a snapshot instead of the live arrays (see stampAll).
pub fn computeBbox(
    positions: [][2]f32,
    dimensions: [][2]f32,
    template: MacroTemplate,
) [2]f32 {
    var max_x: f32 = 0.0;
    var max_y: f32 = 0.0;
    for (template.device_indices) |di| {
        max_x = @max(max_x, positions[di][0] + dimensions[di][0]);
        max_y = @max(max_y, positions[di][1] + dimensions[di][1]);
    }
    return .{ max_x, max_y };
}

/// Propagate unit-cell positions to all macro instances.
///
/// For each instance device at local index k, the global position is:
///   instance.position + Transform.apply(template.device[k].local_pos, bbox)
///
/// A snapshot of device positions is taken before any writes because the
/// first instance shares device indices with the template.
pub fn stampAll(
    allocator: std.mem.Allocator,
    devices: *device_arrays_mod.DeviceArrays,
    macros: *const MacroArrays,
) !void {
    if (macros.instance_count == 0) return;
    const n = devices.len;
    const snap = try allocator.alloc([2]f32, n);
    defer allocator.free(snap);
    @memcpy(snap, devices.positions[0..n]);

    for (macros.instances[0..macros.instance_count]) |inst| {
        const tmpl = macros.templates[inst.template_id];
        const bbox = computeBbox(snap, devices.dimensions, tmpl);
        for (inst.device_indices, 0..) |dev_idx, local_k| {
            if (local_k >= tmpl.device_indices.len) continue;
            const local_pos = snap[tmpl.device_indices[local_k]];
            const tp = inst.transform.apply(local_pos, bbox);
            devices.positions[dev_idx] = .{
                inst.position[0] + tp[0],
                inst.position[1] + tp[1],
            };
        }
    }
}

// ─── Tests ───────────────────────────────────────────────────────────────────

test "computeBbox single device at origin" {
    const alloc = std.testing.allocator;
    var devices = try device_arrays_mod.DeviceArrays.init(alloc, 1);
    defer devices.deinit();
    devices.positions[0] = .{ 0.0, 0.0 };
    devices.dimensions[0] = .{ 3.0, 4.0 };
    var dev_idx = [_]u32{0};
    var port_idx = [_]u32{};
    const tmpl = MacroTemplate{
        .name = "t",
        .device_indices = &dev_idx,
        .port_net_indices = &port_idx,
    };
    const bb = computeBbox(devices.positions[0..1], devices.dimensions[0..1], tmpl);
    try std.testing.expectApproxEqAbs(@as(f32, 3.0), bb[0], 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 4.0), bb[1], 1e-5);
}

test "computeBbox two devices" {
    const alloc = std.testing.allocator;
    var devices = try device_arrays_mod.DeviceArrays.init(alloc, 2);
    defer devices.deinit();
    devices.positions[0] = .{ 0.0, 0.0 };
    devices.dimensions[0] = .{ 2.0, 3.0 };
    devices.positions[1] = .{ 3.0, 0.0 };
    devices.dimensions[1] = .{ 2.0, 5.0 };
    var indices = [_]u32{ 0, 1 };
    var port_idx2 = [_]u32{};
    const tmpl = MacroTemplate{
        .name = "t",
        .device_indices = &indices,
        .port_net_indices = &port_idx2,
    };
    const bb = computeBbox(devices.positions[0..2], devices.dimensions[0..2], tmpl);
    try std.testing.expectApproxEqAbs(@as(f32, 5.0), bb[0], 1e-5); // 3+2
    try std.testing.expectApproxEqAbs(@as(f32, 5.0), bb[1], 1e-5); // max(3,5)
}

test "stampAll identity transform: 4 instances" {
    const alloc = std.testing.allocator;
    var devices = try device_arrays_mod.DeviceArrays.init(alloc, 4);
    defer devices.deinit();
    const params = core_types.DeviceParams{ .w = 1.0, .l = 0.18, .fingers = 1, .mult = 1, .value = 0.0 };
    for (0..4) |i| {
        devices.types[i] = .nmos;
        devices.params[i] = params;
        devices.positions[i] = .{ 0.0, 0.0 };
        devices.dimensions[i] = .{ 2.0, 3.0 };
    }

    var pins = try pin_edge_arrays_mod.PinEdgeArrays.init(alloc, 16);
    defer pins.deinit();
    const terms = [_]core_types.TerminalType{ .gate, .drain, .source, .body };
    for (0..4) |d| {
        for (0..4) |t| {
            const p = d * 4 + t;
            pins.device[p] = DeviceIdx.fromInt(@intCast(d));
            pins.net[p] = NetIdx.fromInt(@intCast(d * 4 + t));
            pins.terminal[p] = terms[t];
        }
    }
    pins.len = 16;

    var adj = try adjacency_mod.FlatAdjList.build(alloc, &pins, 4, 16);
    defer adj.deinit();

    var macros = try detect_mod.detectStructural(alloc, &devices, &pins, &adj, types_mod.MacroConfig{});
    defer macros.deinit();
    try std.testing.expectEqual(@as(u32, 4), macros.instance_count);

    // Assign instance positions: instance i at (i*10, 0)
    for (macros.instances[0..macros.instance_count], 0..) |*inst, i| {
        inst.position = .{ @as(f32, @floatFromInt(i)) * 10.0, 0.0 };
    }

    try stampAll(alloc, &devices, &macros);

    // Template device (dev 0) local_pos was (0,0); bbox = (2,3).
    // Identity transform: global = inst.position + (0,0) = inst.position.
    for (macros.instances[0..macros.instance_count], 0..) |inst, i| {
        const dev_idx = inst.device_indices[0];
        const expected_x: f32 = @as(f32, @floatFromInt(i)) * 10.0;
        try std.testing.expectApproxEqAbs(expected_x, devices.positions[dev_idx][0], 1e-4);
        try std.testing.expectApproxEqAbs(@as(f32, 0.0), devices.positions[dev_idx][1], 1e-4);
    }
}

test "stampAll mirror_x: instance position reflected" {
    const alloc = std.testing.allocator;
    var devices = try device_arrays_mod.DeviceArrays.init(alloc, 4);
    defer devices.deinit();
    const params = core_types.DeviceParams{ .w = 1.0, .l = 0.18, .fingers = 1, .mult = 1, .value = 0.0 };
    for (0..4) |i| {
        devices.types[i] = .nmos;
        devices.params[i] = params;
        devices.positions[i] = .{ 0.0, 0.0 };
        devices.dimensions[i] = .{ 2.0, 3.0 };
    }

    var pins = try pin_edge_arrays_mod.PinEdgeArrays.init(alloc, 16);
    defer pins.deinit();
    const terms = [_]core_types.TerminalType{ .gate, .drain, .source, .body };
    for (0..4) |d| {
        for (0..4) |t| {
            const p = d * 4 + t;
            pins.device[p] = DeviceIdx.fromInt(@intCast(d));
            pins.net[p] = NetIdx.fromInt(@intCast(d * 4 + t));
            pins.terminal[p] = terms[t];
        }
    }
    pins.len = 16;

    var adj = try adjacency_mod.FlatAdjList.build(alloc, &pins, 4, 16);
    defer adj.deinit();

    var macros = try detect_mod.detectStructural(alloc, &devices, &pins, &adj, types_mod.MacroConfig{});
    defer macros.deinit();

    // Instance 1: mirror_x, position (5, 7)
    macros.instances[1].position = .{ 5.0, 7.0 };
    macros.instances[1].transform = .{ .mirror_x = true };

    try stampAll(alloc, &devices, &macros);

    // template local_pos = (0, 0), bbox = (2, 3)
    // mirror_x: x' = bbox[0] - x = 2 - 0 = 2
    // global = (5 + 2, 7 + 0) = (7, 7)
    const dev1 = macros.instances[1].device_indices[0];
    try std.testing.expectApproxEqAbs(@as(f32, 7.0), devices.positions[dev1][0], 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 7.0), devices.positions[dev1][1], 1e-4);
}
