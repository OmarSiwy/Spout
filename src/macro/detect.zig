const std = @import("std");
const types_mod = @import("types.zig");
const core_types = @import("../core/types.zig");
const device_arrays_mod = @import("../core/device_arrays.zig");
const net_arrays_mod = @import("../core/net_arrays.zig");
const pin_edge_arrays_mod = @import("../core/pin_edge_arrays.zig");
const adjacency_mod = @import("../core/adjacency.zig");
const netlist_types = @import("../netlist/types.zig");

const MacroArrays = types_mod.MacroArrays;
const MacroConfig = types_mod.MacroConfig;
const MacroTemplate = types_mod.MacroTemplate;
const MacroInstance = types_mod.MacroInstance;
const DeviceType = core_types.DeviceType;
const DeviceIdx = core_types.DeviceIdx;
const NetIdx = core_types.NetIdx;

// Managed ArrayList (stores allocator internally, deinit takes no args).
fn ManagedList(comptime T: type) type {
    return std.array_list.Managed(T);
}

/// Stage 1: Group X-instances (device_type == .subckt) by subckt_type name.
pub fn detectNamed(
    allocator: std.mem.Allocator,
    devices: *const device_arrays_mod.DeviceArrays,
    parse_devices: []const netlist_types.DeviceInfo,
    cfg: MacroConfig,
) !MacroArrays {
    var result = try MacroArrays.init(allocator, devices.len);
    errdefer result.deinit();
    if (devices.len == 0) return result;

    var groups = std.StringHashMap(ManagedList(u32)).init(allocator);
    defer {
        var it = groups.iterator();
        while (it.next()) |entry| entry.value_ptr.deinit();
        groups.deinit();
    }

    for (0..devices.len) |i| {
        if (parse_devices[i].device_type != .subckt) continue;
        const stype = parse_devices[i].subckt_type;
        if (stype.len == 0) continue;
        const gop = try groups.getOrPut(stype);
        if (!gop.found_existing) gop.value_ptr.* = ManagedList(u32).init(allocator);
        try gop.value_ptr.append(@intCast(i));
    }

    var templates = ManagedList(MacroTemplate).init(allocator);
    errdefer {
        for (templates.items) |*t| {
            allocator.free(t.device_indices);
            allocator.free(t.port_net_indices);
        }
        templates.deinit();
    }
    var instances = ManagedList(MacroInstance).init(allocator);
    errdefer {
        for (instances.items) |*inst| allocator.free(inst.device_indices);
        instances.deinit();
    }

    var it = groups.iterator();
    while (it.next()) |entry| {
        const dev_list = entry.value_ptr.items;
        if (dev_list.len < cfg.min_instance_count) continue;
        const tmpl_id: u32 = @intCast(templates.items.len);
        const unit_indices = try allocator.alloc(u32, 1);
        unit_indices[0] = dev_list[0];
        try templates.append(.{
            .name = try allocator.dupe(u8, entry.key_ptr.*),
            .device_indices = unit_indices,
            .port_net_indices = try allocator.alloc(u32, 0),
        });
        for (dev_list, 0..) |dev_idx, k| {
            const inst_idx: u32 = @intCast(instances.items.len);
            const di = try allocator.alloc(u32, 1);
            di[0] = dev_idx;
            try instances.append(.{
                .template_id = tmpl_id,
                .device_indices = di,
                .position = .{ 0.0, 0.0 },
                .transform = .{},
            });
            result.device_inst[dev_idx] = @intCast(inst_idx);
            result.device_local[dev_idx] = @intCast(k);
        }
    }

    result.templates = try templates.toOwnedSlice();
    result.instances = try instances.toOwnedSlice();
    result.template_count = @intCast(result.templates.len);
    result.instance_count = @intCast(result.instances.len);
    return result;
}

fn deviceSignature(
    devices: *const device_arrays_mod.DeviceArrays,
    d: u32,
    tolerance: f32,
) u64 {
    const dt: u8 = @intFromEnum(devices.types[d]);
    const p = devices.params[d];
    const w_bits: u32 = if (tolerance > 0) @intFromFloat(@round(p.w / tolerance)) else @bitCast(p.w);
    const l_bits: u32 = if (tolerance > 0) @intFromFloat(@round(p.l / tolerance)) else @bitCast(p.l);
    const v_bits: u32 = if (tolerance > 0) @intFromFloat(@round(p.value / tolerance)) else @bitCast(p.value);
    var h = std.hash.Wyhash.init(0xdeadbeef);
    h.update(std.mem.asBytes(&dt));
    h.update(std.mem.asBytes(&w_bits));
    h.update(std.mem.asBytes(&l_bits));
    h.update(std.mem.asBytes(&p.fingers));
    h.update(std.mem.asBytes(&p.mult));
    h.update(std.mem.asBytes(&v_bits));
    return h.final();
}

fn wlRound(
    devices: *const device_arrays_mod.DeviceArrays,
    pins: *const pin_edge_arrays_mod.PinEdgeArrays,
    adj: *const adjacency_mod.FlatAdjList,
    prev: []const u64,
    next: []u64,
    allocator: std.mem.Allocator,
) !void {
    const n = devices.len;
    for (0..n) |d| {
        var neighbor_labels = ManagedList(u64).init(allocator);
        defer neighbor_labels.deinit();
        const d_pins = adj.pinsOnDevice(DeviceIdx.fromInt(@intCast(d)));
        for (d_pins) |pin_idx| {
            const net = pins.net[pin_idx.toInt()];
            const net_pins = adj.pinsOnNet(net);
            for (net_pins) |np| {
                const nd = pins.device[np.toInt()].toInt();
                if (nd == d) continue;
                try neighbor_labels.append(prev[nd]);
            }
        }
        std.mem.sort(u64, neighbor_labels.items, {}, std.sort.asc(u64));
        var h = std.hash.Wyhash.init(prev[d]);
        for (neighbor_labels.items) |lbl| h.update(std.mem.asBytes(&lbl));
        next[d] = h.final();
    }
}

pub fn detectStructural(
    allocator: std.mem.Allocator,
    devices: *const device_arrays_mod.DeviceArrays,
    pins: *const pin_edge_arrays_mod.PinEdgeArrays,
    adj: *const adjacency_mod.FlatAdjList,
    cfg: MacroConfig,
) !MacroArrays {
    const n = devices.len;
    var result = try MacroArrays.init(allocator, n);
    errdefer result.deinit();
    if (n == 0 or !cfg.enable_structural) return result;

    var labels_a = try allocator.alloc(u64, n);
    defer allocator.free(labels_a);
    const labels_b = try allocator.alloc(u64, n);
    defer allocator.free(labels_b);

    for (0..n) |d| labels_a[d] = deviceSignature(devices, @intCast(d), cfg.param_tolerance);
    try wlRound(devices, pins, adj, labels_a, labels_b, allocator);
    try wlRound(devices, pins, adj, labels_b, labels_a, allocator);

    var groups = std.AutoHashMap(u64, ManagedList(u32)).init(allocator);
    defer {
        var git = groups.iterator();
        while (git.next()) |e| e.value_ptr.deinit();
        groups.deinit();
    }
    for (0..n) |d| {
        const gop = try groups.getOrPut(labels_a[d]);
        if (!gop.found_existing) gop.value_ptr.* = ManagedList(u32).init(allocator);
        try gop.value_ptr.append(@intCast(d));
    }

    var templates = ManagedList(MacroTemplate).init(allocator);
    errdefer {
        for (templates.items) |*t| {
            allocator.free(t.device_indices);
            allocator.free(t.port_net_indices);
        }
        templates.deinit();
    }
    var instances = ManagedList(MacroInstance).init(allocator);
    errdefer {
        for (instances.items) |*i| allocator.free(i.device_indices);
        instances.deinit();
    }

    var tmpl_counter: u32 = 0;
    var git = groups.iterator();
    while (git.next()) |entry| {
        const dev_list = entry.value_ptr.items;
        if (dev_list.len < cfg.min_instance_count) continue;
        const tmpl_id = tmpl_counter;
        tmpl_counter += 1;
        const name_buf = try std.fmt.allocPrint(allocator, "macro_{d}", .{tmpl_id});
        const unit_indices = try allocator.dupe(u32, dev_list[0..1]);
        try templates.append(.{
            .name = name_buf,
            .device_indices = unit_indices,
            .port_net_indices = try allocator.alloc(u32, 0),
        });
        for (dev_list, 0..) |dev_idx, k| {
            const inst_idx: u32 = @intCast(instances.items.len);
            const di = try allocator.alloc(u32, 1);
            di[0] = dev_idx;
            try instances.append(.{
                .template_id = tmpl_id,
                .device_indices = di,
                .position = .{ 0.0, 0.0 },
                .transform = .{},
            });
            result.device_inst[dev_idx] = @intCast(inst_idx);
            result.device_local[dev_idx] = @intCast(k);
        }
    }
    result.templates = try templates.toOwnedSlice();
    result.instances = try instances.toOwnedSlice();
    result.template_count = @intCast(result.templates.len);
    result.instance_count = @intCast(result.instances.len);
    return result;
}

/// Top-level entry point. Tries named first; falls back to structural.
pub fn detectMacros(
    allocator: std.mem.Allocator,
    devices: *const device_arrays_mod.DeviceArrays,
    parse_devices: []const netlist_types.DeviceInfo,
    pins: *const pin_edge_arrays_mod.PinEdgeArrays,
    adj: *const adjacency_mod.FlatAdjList,
    cfg: MacroConfig,
) !MacroArrays {
    const named = try detectNamed(allocator, devices, parse_devices, cfg);
    if (named.template_count > 0) return named;
    var named_copy = named;
    named_copy.deinit();
    if (!cfg.enable_structural) return MacroArrays.init(allocator, devices.len);
    return detectStructural(allocator, devices, pins, adj, cfg);
}

// ─── Tests ───────────────────────────────────────────────────────────────────

test "detectNamed: 4 instances same subckt → 1 template 4 instances" {
    const alloc = std.testing.allocator;
    var devices = try device_arrays_mod.DeviceArrays.init(alloc, 4);
    defer devices.deinit();
    for (0..4) |i| devices.types[i] = .subckt;
    const parse_devices = [_]netlist_types.DeviceInfo{
        .{ .name = "X0", .device_type = .subckt, .params = std.mem.zeroes(core_types.DeviceParams), .subckt_type = "sram_cell" },
        .{ .name = "X1", .device_type = .subckt, .params = std.mem.zeroes(core_types.DeviceParams), .subckt_type = "sram_cell" },
        .{ .name = "X2", .device_type = .subckt, .params = std.mem.zeroes(core_types.DeviceParams), .subckt_type = "sram_cell" },
        .{ .name = "X3", .device_type = .subckt, .params = std.mem.zeroes(core_types.DeviceParams), .subckt_type = "sram_cell" },
    };
    var result = try detectNamed(alloc, &devices, &parse_devices, MacroConfig{});
    defer result.deinit();
    try std.testing.expectEqual(@as(u32, 1), result.template_count);
    try std.testing.expectEqual(@as(u32, 4), result.instance_count);
    for (result.device_inst) |v| try std.testing.expect(v >= 0);
}

test "detectNamed: singletons below min_instance_count → no macros" {
    const alloc = std.testing.allocator;
    var devices = try device_arrays_mod.DeviceArrays.init(alloc, 2);
    defer devices.deinit();
    for (0..2) |i| devices.types[i] = .subckt;
    const parse_devices = [_]netlist_types.DeviceInfo{
        .{ .name = "X0", .device_type = .subckt, .params = std.mem.zeroes(core_types.DeviceParams), .subckt_type = "cell_a" },
        .{ .name = "X1", .device_type = .subckt, .params = std.mem.zeroes(core_types.DeviceParams), .subckt_type = "cell_b" },
    };
    var result = try detectNamed(alloc, &devices, &parse_devices, MacroConfig{});
    defer result.deinit();
    try std.testing.expectEqual(@as(u32, 0), result.template_count);
}

test "detectStructural: 4 identical isolated nmos → 1 template 4 instances" {
    const alloc = std.testing.allocator;
    var devices = try device_arrays_mod.DeviceArrays.init(alloc, 4);
    defer devices.deinit();
    const params = core_types.DeviceParams{ .w = 1.0, .l = 0.18, .fingers = 1, .mult = 1, .value = 0.0 };
    for (0..4) |i| {
        devices.types[i] = .nmos;
        devices.params[i] = params;
    }

    // Each device is isolated (4 pins each, all on unique nets)
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

    var result = try detectStructural(alloc, &devices, &pins, &adj, MacroConfig{});
    defer result.deinit();
    try std.testing.expectEqual(@as(u32, 1), result.template_count);
    try std.testing.expectEqual(@as(u32, 4), result.instance_count);
}
