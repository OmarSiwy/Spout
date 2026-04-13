const std = @import("std");
const core_types = @import("../core/types.zig");
const adjacency = @import("../core/adjacency.zig");
const pin_edge_arrays = @import("../core/pin_edge_arrays.zig");
const net_arrays = @import("../core/net_arrays.zig");
const NetArrays = net_arrays.NetArrays;
const device_mod = @import("../core/device_arrays.zig");
const DeviceArrays = device_mod.DeviceArrays;

const DeviceIdx = core_types.DeviceIdx;
const NetIdx = core_types.NetIdx;
const PinIdx = core_types.PinIdx;
const TerminalType = core_types.TerminalType;
const FlatAdjList = adjacency.FlatAdjList;
const PinEdgeArrays = pin_edge_arrays.PinEdgeArrays;

// ─── Effective width ──────────────────────────────────────────────────────────

/// Effective device width accounting for fingers and multiplier.
/// effective_w = params.w * fingers * mult
/// Use this (not raw params.w) for all matching comparisons.
pub fn effectiveW(devices: *const DeviceArrays, dev: DeviceIdx) f32 {
    const i: usize = @intCast(dev.toInt());
    const fingers: f32 = @floatFromInt(@max(@as(u16, 1), devices.params[i].fingers));
    const mult: f32 = @floatFromInt(@max(@as(u16, 1), devices.params[i].mult));
    return devices.params[i].w * fingers * mult;
}

// ─── Float comparison ─────────────────────────────────────────────────────────

/// Relative epsilon comparison for SPICE float parameters.
/// Tolerates 0.01% relative difference + absolute floor.
/// Never use == on parsed SPICE floats.
pub const EPS_REL: f32 = 1e-4;
pub const EPS_ABS: f32 = 1e-12;

pub inline fn approxEq(a: f32, b: f32) bool {
    const diff = @abs(a - b);
    const mag = @max(@abs(a), @abs(b));
    return diff <= EPS_REL * mag + EPS_ABS;
}

// ─── Rail detection ───────────────────────────────────────────────────────────

/// Returns true if the net is a power/ground rail.
/// Primary check: NetArrays.is_power flag (set by SPICE parser).
pub fn isRail(net_idx: NetIdx, nets: *const NetArrays) bool {
    const i: usize = @intCast(net_idx.toInt());
    if (i >= nets.len) return false;
    return nets.is_power[i];
}

// ─── Net device collection ────────────────────────────────────────────────────

/// Fixed-capacity buffer for up to 64 device indices.
/// Used as output buffer for devicesOnNetByTerminal.
pub const DeviceIdxBuf = struct {
    buf: [64]DeviceIdx = undefined,
    len: usize = 0,

    pub fn appendAssumeCapacity(self: *DeviceIdxBuf, idx: DeviceIdx) void {
        std.debug.assert(self.len < self.buf.len);
        self.buf[self.len] = idx;
        self.len += 1;
    }

    pub fn slice(self: *const DeviceIdxBuf) []const DeviceIdx {
        return self.buf[0..self.len];
    }
};

/// Collect all devices that have a pin with the given terminal type on `net`.
/// Results are written into `out` (max 64 devices per net).
pub fn devicesOnNetByTerminal(
    adj: *const FlatAdjList,
    pins: *const PinEdgeArrays,
    net: NetIdx,
    term: TerminalType,
    out: *DeviceIdxBuf,
) void {
    out.len = 0;
    const net_pins = adj.pinsOnNet(net);
    for (net_pins) |pin_idx| {
        const p: usize = @intCast(pin_idx.toInt());
        if (pins.terminal[p] == term) {
            out.appendAssumeCapacity(pins.device[p]);
        }
    }
}

// ─── Pair utilities ───────────────────────────────────────────────────────────

/// Pack two device indices into a u64 key (order-independent).
/// Used for seen-set deduplication in extractConstraints.
pub fn packPair(a: u32, b: u32) u64 {
    const lo = @min(a, b);
    const hi = @max(a, b);
    return (@as(u64, lo) << 32) | @as(u64, hi);
}

/// Return [smaller, larger] device index pair (normalised order).
pub fn normalisePair(a: DeviceIdx, b: DeviceIdx) [2]DeviceIdx {
    return if (a.toInt() <= b.toInt())
        .{ a, b }
    else
        .{ b, a };
}

// ─── Terminal net lookup helpers ─────────────────────────────────────────────
//
// Each function iterates over adj.pinsOnDevice(d) and returns the net
// connected to the pin whose terminal type matches the requested kind.
// Returns null if no such terminal exists on the device (e.g. a resistor
// has no gate terminal).

/// Return the net connected to the *source* terminal of device `d`, or null.
pub fn sourceNet(adj: *const FlatAdjList, pins: *const PinEdgeArrays, d: DeviceIdx) ?NetIdx {
    return terminalNet(adj, pins, d, .source);
}

/// Return the net connected to the *gate* terminal of device `d`, or null.
pub fn gateNet(adj: *const FlatAdjList, pins: *const PinEdgeArrays, d: DeviceIdx) ?NetIdx {
    return terminalNet(adj, pins, d, .gate);
}

/// Return the net connected to the *drain* terminal of device `d`, or null.
pub fn drainNet(adj: *const FlatAdjList, pins: *const PinEdgeArrays, d: DeviceIdx) ?NetIdx {
    return terminalNet(adj, pins, d, .drain);
}

/// Return the net connected to the *body* terminal of device `d`, or null.
pub fn bodyNet(adj: *const FlatAdjList, pins: *const PinEdgeArrays, d: DeviceIdx) ?NetIdx {
    return terminalNet(adj, pins, d, .body);
}

/// Generic helper: find the net connected to the pin of device `d` whose
/// terminal type is `wanted`.
fn terminalNet(
    adj: *const FlatAdjList,
    pins: *const PinEdgeArrays,
    d: DeviceIdx,
    wanted: TerminalType,
) ?NetIdx {
    const device_pins = adj.pinsOnDevice(d);
    for (device_pins) |pin_idx| {
        const p: usize = pin_idx.toInt();
        if (pins.terminal[p] == wanted) {
            return pins.net[p];
        }
    }
    return null;
}

// ─── Tests ───────────────────────────────────────────────────────────────────

test "sourceNet / gateNet / drainNet / bodyNet on a single MOSFET" {
    // One device (D0) with 4 pins: gate→N0, drain→N1, source→N2, body→N3.
    const alloc = std.testing.allocator;

    var pins = try PinEdgeArrays.init(alloc, 4);
    defer pins.deinit();

    // Pin 0: gate  → net 0
    pins.device[0] = DeviceIdx.fromInt(0);
    pins.net[0] = NetIdx.fromInt(0);
    pins.terminal[0] = .gate;

    // Pin 1: drain → net 1
    pins.device[1] = DeviceIdx.fromInt(0);
    pins.net[1] = NetIdx.fromInt(1);
    pins.terminal[1] = .drain;

    // Pin 2: source → net 2
    pins.device[2] = DeviceIdx.fromInt(0);
    pins.net[2] = NetIdx.fromInt(2);
    pins.terminal[2] = .source;

    // Pin 3: body → net 3
    pins.device[3] = DeviceIdx.fromInt(0);
    pins.net[3] = NetIdx.fromInt(3);
    pins.terminal[3] = .body;

    var adj = try FlatAdjList.buildFromSlices(
        alloc,
        1, // 1 device
        4, // 4 nets
        4, // 4 pins
        pins.device,
        pins.net,
    );
    defer adj.deinit();

    try std.testing.expectEqual(NetIdx.fromInt(0), gateNet(&adj, &pins, DeviceIdx.fromInt(0)).?);
    try std.testing.expectEqual(NetIdx.fromInt(1), drainNet(&adj, &pins, DeviceIdx.fromInt(0)).?);
    try std.testing.expectEqual(NetIdx.fromInt(2), sourceNet(&adj, &pins, DeviceIdx.fromInt(0)).?);
    try std.testing.expectEqual(NetIdx.fromInt(3), bodyNet(&adj, &pins, DeviceIdx.fromInt(0)).?);
}

test "terminal lookup returns null for missing terminal" {
    // A resistor (D0) with only anode (pin 0) and cathode (pin 1) — no gate.
    const alloc = std.testing.allocator;

    var pins = try PinEdgeArrays.init(alloc, 2);
    defer pins.deinit();

    pins.device[0] = DeviceIdx.fromInt(0);
    pins.net[0] = NetIdx.fromInt(0);
    pins.terminal[0] = .anode;

    pins.device[1] = DeviceIdx.fromInt(0);
    pins.net[1] = NetIdx.fromInt(1);
    pins.terminal[1] = .cathode;

    var adj = try FlatAdjList.buildFromSlices(alloc, 1, 2, 2, pins.device, pins.net);
    defer adj.deinit();

    try std.testing.expectEqual(@as(?NetIdx, null), gateNet(&adj, &pins, DeviceIdx.fromInt(0)));
    try std.testing.expectEqual(@as(?NetIdx, null), drainNet(&adj, &pins, DeviceIdx.fromInt(0)));
    try std.testing.expectEqual(@as(?NetIdx, null), sourceNet(&adj, &pins, DeviceIdx.fromInt(0)));
    try std.testing.expectEqual(@as(?NetIdx, null), bodyNet(&adj, &pins, DeviceIdx.fromInt(0)));
}

test "effectiveW: fingers and mult scale width" {
    const alloc = std.testing.allocator;
    var devices = try DeviceArrays.init(alloc, 2);
    defer devices.deinit();
    // D0: W=1µm, fingers=4, mult=1 → effective = 4µm
    devices.params[0] = .{ .w = 1.0e-6, .l = 0.13e-6, .fingers = 4, .mult = 1, .value = 0.0 };
    // D1: W=2µm, fingers=2, mult=1 → effective = 4µm
    devices.params[1] = .{ .w = 2.0e-6, .l = 0.13e-6, .fingers = 2, .mult = 1, .value = 0.0 };

    const ew0 = effectiveW(&devices, DeviceIdx.fromInt(0));
    const ew1 = effectiveW(&devices, DeviceIdx.fromInt(1));
    try std.testing.expectApproxEqAbs(4.0e-6, ew0, 1e-15);
    try std.testing.expectApproxEqAbs(4.0e-6, ew1, 1e-15);
    try std.testing.expect(approxEq(ew0, ew1));
}

test "approxEq: near-equal floats pass, far floats fail" {
    try std.testing.expect(approxEq(2.0e-6, 2.0e-6 + 1e-15));
    try std.testing.expect(!approxEq(2.0e-6, 4.0e-6));
    try std.testing.expect(approxEq(0.0, 0.0));
    try std.testing.expect(approxEq(0.0, EPS_ABS * 0.5));
}

test "isRail: is_power flag" {
    const alloc = std.testing.allocator;
    var nets = try NetArrays.init(alloc, 3);
    defer nets.deinit();
    nets.is_power[0] = true;
    nets.is_power[1] = false;
    nets.is_power[2] = true;

    try std.testing.expect(isRail(NetIdx.fromInt(0), &nets));
    try std.testing.expect(!isRail(NetIdx.fromInt(1), &nets));
    try std.testing.expect(isRail(NetIdx.fromInt(2), &nets));
}

test "packPair is order-independent" {
    try std.testing.expectEqual(packPair(0, 5), packPair(5, 0));
    try std.testing.expect(packPair(0, 1) != packPair(0, 2));
    try std.testing.expectEqual(packPair(3, 3), packPair(3, 3)); // self-sym
}

test "normalisePair always returns smaller index first" {
    const p1 = normalisePair(DeviceIdx.fromInt(3), DeviceIdx.fromInt(1));
    try std.testing.expectEqual(@as(u32, 1), p1[0].toInt());
    try std.testing.expectEqual(@as(u32, 3), p1[1].toInt());

    const p2 = normalisePair(DeviceIdx.fromInt(0), DeviceIdx.fromInt(5));
    try std.testing.expectEqual(@as(u32, 0), p2[0].toInt());
    try std.testing.expectEqual(@as(u32, 5), p2[1].toInt());
}

test "devicesOnNetByTerminal finds source-connected devices" {
    const alloc = std.testing.allocator;
    var pins = try PinEdgeArrays.init(alloc, 8);
    defer pins.deinit();

    // D0: gate=N0, drain=N1, source=N2, body=N3
    pins.device[0] = DeviceIdx.fromInt(0);
    pins.net[0] = NetIdx.fromInt(0);
    pins.terminal[0] = .gate;
    pins.device[1] = DeviceIdx.fromInt(0);
    pins.net[1] = NetIdx.fromInt(1);
    pins.terminal[1] = .drain;
    pins.device[2] = DeviceIdx.fromInt(0);
    pins.net[2] = NetIdx.fromInt(2);
    pins.terminal[2] = .source;
    pins.device[3] = DeviceIdx.fromInt(0);
    pins.net[3] = NetIdx.fromInt(3);
    pins.terminal[3] = .body;
    // D1: gate=N4, drain=N5, source=N2, body=N3
    pins.device[4] = DeviceIdx.fromInt(1);
    pins.net[4] = NetIdx.fromInt(4);
    pins.terminal[4] = .gate;
    pins.device[5] = DeviceIdx.fromInt(1);
    pins.net[5] = NetIdx.fromInt(5);
    pins.terminal[5] = .drain;
    pins.device[6] = DeviceIdx.fromInt(1);
    pins.net[6] = NetIdx.fromInt(2);
    pins.terminal[6] = .source;
    pins.device[7] = DeviceIdx.fromInt(1);
    pins.net[7] = NetIdx.fromInt(3);
    pins.terminal[7] = .body;

    var adj = try FlatAdjList.buildFromSlices(alloc, 2, 6, 8, pins.device, pins.net);
    defer adj.deinit();

    var out: DeviceIdxBuf = .{};
    devicesOnNetByTerminal(&adj, &pins, NetIdx.fromInt(2), .source, &out);
    try std.testing.expectEqual(@as(usize, 2), out.len);
}
