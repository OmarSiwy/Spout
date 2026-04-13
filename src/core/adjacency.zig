const std = @import("std");
const types = @import("types.zig");
const pin_edge = @import("pin_edge_arrays.zig");
const utility = @import("../utility/lib.zig");

const DeviceIdx = types.DeviceIdx;
const NetIdx = types.NetIdx;
const PinIdx = types.PinIdx;
const PinEdgeArrays = pin_edge.PinEdgeArrays;

/// Single-dimension CSR index over PinIdx values.  Uses the generic
/// utility.Csr(PinIdx) so the count/prefix-sum/scatter logic lives once.
const CsrIndex = utility.Csr(PinIdx);

/// Compressed-Sparse-Row flat adjacency list for the device-pin and net-pin
/// bipartite graph.  Built once from pin edges; provides O(1) lookup of all
/// pins on a device or net.
pub const FlatAdjList = struct {
    /// device_pin_offsets[d] .. device_pin_offsets[d+1] -> pins on device d.
    device_pin_offsets: []u32,
    device_pin_list: []PinIdx,

    /// net_pin_offsets[n] .. net_pin_offsets[n+1] -> pins on net n.
    net_pin_offsets: []u32,
    net_pin_list: []PinIdx,

    allocator: std.mem.Allocator,

    /// Build the CSR adjacency from a PinEdgeArrays instance.
    pub fn build(
        allocator: std.mem.Allocator,
        pins: *const PinEdgeArrays,
        num_devices: u32,
        num_nets: u32,
    ) !FlatAdjList {
        return buildFromSlices(allocator, num_devices, num_nets, pins.len, pins.device, pins.net);
    }

    /// Build the CSR adjacency from raw device/net slices.
    pub fn buildFromSlices(
        allocator: std.mem.Allocator,
        num_devices: u32,
        num_nets: u32,
        num_pins: u32,
        device_arr: []const DeviceIdx,
        net_arr: []const NetIdx,
    ) !FlatAdjList {
        const np: usize = @intCast(num_pins);

        // Reinterpret the typed index slices as raw u32 slices for the
        // generic CSR builder.  Safe because DeviceIdx/NetIdx are enum(u32).
        const dev_keys: []const u32 = @ptrCast(device_arr[0..np]);
        const net_keys: []const u32 = @ptrCast(net_arr[0..np]);

        var dev_csr = try CsrIndex.build(allocator, @intCast(num_devices), np, dev_keys);
        errdefer dev_csr.deinit(allocator);

        var net_csr = try CsrIndex.build(allocator, @intCast(num_nets), np, net_keys);
        errdefer net_csr.deinit(allocator);

        return FlatAdjList{
            .device_pin_offsets = dev_csr.offsets,
            .device_pin_list = dev_csr.list,
            .net_pin_offsets = net_csr.offsets,
            .net_pin_list = net_csr.list,
            .allocator = allocator,
        };
    }

    /// Return the slice of pin indices connected to the given device.
    pub fn pinsOnDevice(self: *const FlatAdjList, d: DeviceIdx) []PinIdx {
        const di: usize = @intCast(d.toInt());
        return self.device_pin_list[self.device_pin_offsets[di]..self.device_pin_offsets[di + 1]];
    }

    /// Return the slice of pin indices connected to the given net.
    pub fn pinsOnNet(self: *const FlatAdjList, n: NetIdx) []PinIdx {
        const ni: usize = @intCast(n.toInt());
        return self.net_pin_list[self.net_pin_offsets[ni]..self.net_pin_offsets[ni + 1]];
    }

    /// Free all owned slices and invalidate the struct.
    pub fn deinit(self: *FlatAdjList) void {
        self.allocator.free(self.device_pin_offsets);
        self.allocator.free(self.device_pin_list);
        self.allocator.free(self.net_pin_offsets);
        self.allocator.free(self.net_pin_list);
        self.* = undefined;
    }
};

// ─── Tests ───────────────────────────────────────────────────────────────────

test "FlatAdjList build and query" {
    const allocator = std.testing.allocator;

    // Two devices, two nets, four pins:
    //   pin 0: device 0, net 0 (gate)
    //   pin 1: device 0, net 1 (drain)
    //   pin 2: device 1, net 1 (gate)
    //   pin 3: device 1, net 0 (drain)
    var pins = try PinEdgeArrays.init(allocator, 4);
    defer pins.deinit();

    pins.device[0] = DeviceIdx.fromInt(0);
    pins.net[0] = NetIdx.fromInt(0);
    pins.terminal[0] = .gate;

    pins.device[1] = DeviceIdx.fromInt(0);
    pins.net[1] = NetIdx.fromInt(1);
    pins.terminal[1] = .drain;

    pins.device[2] = DeviceIdx.fromInt(1);
    pins.net[2] = NetIdx.fromInt(1);
    pins.terminal[2] = .gate;

    pins.device[3] = DeviceIdx.fromInt(1);
    pins.net[3] = NetIdx.fromInt(0);
    pins.terminal[3] = .drain;

    var adj = try FlatAdjList.build(allocator, &pins, 2, 2);
    defer adj.deinit();

    // Device 0 should have 2 pins.
    const d0 = adj.pinsOnDevice(DeviceIdx.fromInt(0));
    try std.testing.expectEqual(@as(usize, 2), d0.len);

    // Device 1 should have 2 pins.
    const d1 = adj.pinsOnDevice(DeviceIdx.fromInt(1));
    try std.testing.expectEqual(@as(usize, 2), d1.len);

    // Net 0 should have 2 pins (pin 0 and pin 3).
    const n0 = adj.pinsOnNet(NetIdx.fromInt(0));
    try std.testing.expectEqual(@as(usize, 2), n0.len);

    // Net 1 should have 2 pins (pin 1 and pin 2).
    const n1 = adj.pinsOnNet(NetIdx.fromInt(1));
    try std.testing.expectEqual(@as(usize, 2), n1.len);
}

test "FlatAdjList empty" {
    const allocator = std.testing.allocator;
    var pins = try PinEdgeArrays.init(allocator, 0);
    defer pins.deinit();

    var adj = try FlatAdjList.build(allocator, &pins, 0, 0);
    defer adj.deinit();

    try std.testing.expectEqual(@as(usize, 1), adj.device_pin_offsets.len);
    try std.testing.expectEqual(@as(usize, 1), adj.net_pin_offsets.len);
}

test "FlatAdjList 5-device 3-net circuit" {
    const allocator = std.testing.allocator;

    // Circuit with 5 devices and 3 nets:
    //   D0: gate=N0, drain=N1, source=N2, body=N2   (4 pins)
    //   D1: gate=N0, drain=N1, source=N2, body=N2   (4 pins)
    //   D2: gate=N1, drain=N2, source=N0, body=N0   (4 pins)
    //   D3: gate=N2, drain=N0, source=N1, body=N1   (4 pins)
    //   D4: gate=N0, drain=N2, source=N1, body=N2   (4 pins)
    // Total: 20 pins

    var pins_arr = try PinEdgeArrays.init(allocator, 20);
    defer pins_arr.deinit();

    // Helper to set mosfet pins
    const d_nets = [5][4]u32{
        .{ 0, 1, 2, 2 }, // D0: gate=0, drain=1, source=2, body=2
        .{ 0, 1, 2, 2 }, // D1: gate=0, drain=1, source=2, body=2
        .{ 1, 2, 0, 0 }, // D2
        .{ 2, 0, 1, 1 }, // D3
        .{ 0, 2, 1, 2 }, // D4
    };
    const terminal_order = [4]types.TerminalType{ .gate, .drain, .source, .body };

    for (0..5) |dev| {
        for (0..4) |t| {
            const pin_idx = dev * 4 + t;
            pins_arr.device[pin_idx] = DeviceIdx.fromInt(@intCast(dev));
            pins_arr.net[pin_idx] = NetIdx.fromInt(d_nets[dev][t]);
            pins_arr.terminal[pin_idx] = terminal_order[t];
        }
    }

    var adj = try FlatAdjList.build(allocator, &pins_arr, 5, 3);
    defer adj.deinit();

    // Each device should have exactly 4 pins
    for (0..5) |d| {
        const dev_pins = adj.pinsOnDevice(DeviceIdx.fromInt(@intCast(d)));
        try std.testing.expectEqual(@as(usize, 4), dev_pins.len);
    }

    // Count pins per net:
    // N0: D0.gate, D1.gate, D2.source, D2.body, D3.drain, D4.gate = 6
    // N1: D0.drain, D1.drain, D2.gate, D3.source, D3.body, D4.source = 6
    // N2: D0.source, D0.body, D1.source, D1.body, D2.drain, D3.gate, D4.drain, D4.body = 8
    const n0_pins = adj.pinsOnNet(NetIdx.fromInt(0));
    try std.testing.expectEqual(@as(usize, 6), n0_pins.len);

    const n1_pins = adj.pinsOnNet(NetIdx.fromInt(1));
    try std.testing.expectEqual(@as(usize, 6), n1_pins.len);

    const n2_pins = adj.pinsOnNet(NetIdx.fromInt(2));
    try std.testing.expectEqual(@as(usize, 8), n2_pins.len);

    // Total pins on all nets should equal total pins
    try std.testing.expectEqual(@as(usize, 20), n0_pins.len + n1_pins.len + n2_pins.len);
}

test "FlatAdjList buildFromSlices matches build" {
    const allocator = std.testing.allocator;

    // Build from PinEdgeArrays
    var pins_arr = try PinEdgeArrays.init(allocator, 4);
    defer pins_arr.deinit();

    pins_arr.device[0] = DeviceIdx.fromInt(0);
    pins_arr.net[0] = NetIdx.fromInt(0);
    pins_arr.device[1] = DeviceIdx.fromInt(0);
    pins_arr.net[1] = NetIdx.fromInt(1);
    pins_arr.device[2] = DeviceIdx.fromInt(1);
    pins_arr.net[2] = NetIdx.fromInt(0);
    pins_arr.device[3] = DeviceIdx.fromInt(1);
    pins_arr.net[3] = NetIdx.fromInt(1);

    var adj1 = try FlatAdjList.build(allocator, &pins_arr, 2, 2);
    defer adj1.deinit();

    var adj2 = try FlatAdjList.buildFromSlices(
        allocator,
        2,
        2,
        4,
        pins_arr.device,
        pins_arr.net,
    );
    defer adj2.deinit();

    // Both should report same pin counts per device and net
    try std.testing.expectEqual(adj1.pinsOnDevice(DeviceIdx.fromInt(0)).len, adj2.pinsOnDevice(DeviceIdx.fromInt(0)).len);
    try std.testing.expectEqual(adj1.pinsOnDevice(DeviceIdx.fromInt(1)).len, adj2.pinsOnDevice(DeviceIdx.fromInt(1)).len);
    try std.testing.expectEqual(adj1.pinsOnNet(NetIdx.fromInt(0)).len, adj2.pinsOnNet(NetIdx.fromInt(0)).len);
    try std.testing.expectEqual(adj1.pinsOnNet(NetIdx.fromInt(1)).len, adj2.pinsOnNet(NetIdx.fromInt(1)).len);
}

test "FlatAdjList single device many pins" {
    const allocator = std.testing.allocator;

    // 1 device with 4 pins on 4 different nets
    var pins_arr = try PinEdgeArrays.init(allocator, 4);
    defer pins_arr.deinit();

    for (0..4) |i| {
        pins_arr.device[i] = DeviceIdx.fromInt(0);
        pins_arr.net[i] = NetIdx.fromInt(@intCast(i));
    }

    var adj = try FlatAdjList.build(allocator, &pins_arr, 1, 4);
    defer adj.deinit();

    // Device 0 should have 4 pins
    try std.testing.expectEqual(@as(usize, 4), adj.pinsOnDevice(DeviceIdx.fromInt(0)).len);

    // Each net should have exactly 1 pin
    for (0..4) |n| {
        try std.testing.expectEqual(@as(usize, 1), adj.pinsOnNet(NetIdx.fromInt(@intCast(n))).len);
    }
}
