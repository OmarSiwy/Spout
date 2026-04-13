const std = @import("std");
const core_types = @import("../core/types.zig");
const adjacency = @import("../core/adjacency.zig");
const pin_edge_mod = @import("../core/pin_edge_arrays.zig");
const constraint_mod = @import("../core/constraint_arrays.zig");
const device_mod = @import("../core/device_arrays.zig");
const net_mod = @import("../core/net_arrays.zig");
const extract = @import("extract.zig");
const patterns = @import("patterns.zig");

const DeviceIdx = core_types.DeviceIdx;
const NetIdx = core_types.NetIdx;
const DeviceType = core_types.DeviceType;
const DeviceParams = core_types.DeviceParams;
const ConstraintType = core_types.ConstraintType;
const TerminalType = core_types.TerminalType;
const FlatAdjList = adjacency.FlatAdjList;
const PinEdgeArrays = pin_edge_mod.PinEdgeArrays;
const ConstraintArrays = constraint_mod.ConstraintArrays;
const DeviceArrays = device_mod.DeviceArrays;
const NetArrays = net_mod.NetArrays;

// ─── Net helper ──────────────────────────────────────────────────────────────

/// Create NetArrays with is_power set for specified net indices.
fn makeNets(alloc: std.mem.Allocator, count: u32, power_nets: []const u32) !NetArrays {
    var nets = try NetArrays.init(alloc, count);
    for (power_nets) |n| nets.is_power[n] = true;
    return nets;
}

// ─── Test helpers ────────────────────────────────────────────────────────────

/// Populate four MOSFET pins (gate, drain, source, body) for a device,
/// starting at pin index `base`. Returns the next available pin index.
fn setMosfetPins(
    pins: *PinEdgeArrays,
    base: usize,
    device: u32,
    gate_net: u32,
    drain_net: u32,
    source_net: u32,
    body_net: u32,
) void {
    const d = DeviceIdx.fromInt(device);

    // gate
    pins.device[base + 0] = d;
    pins.net[base + 0] = NetIdx.fromInt(gate_net);
    pins.terminal[base + 0] = .gate;

    // drain
    pins.device[base + 1] = d;
    pins.net[base + 1] = NetIdx.fromInt(drain_net);
    pins.terminal[base + 1] = .drain;

    // source
    pins.device[base + 2] = d;
    pins.net[base + 2] = NetIdx.fromInt(source_net);
    pins.terminal[base + 2] = .source;

    // body
    pins.device[base + 3] = d;
    pins.net[base + 3] = NetIdx.fromInt(body_net);
    pins.terminal[base + 3] = .body;
}

/// Return the number of constraints of a given type in the result.
fn countConstraintsOfType(result: *const ConstraintArrays, ctype: ConstraintType) u32 {
    var count: u32 = 0;
    for (0..result.len) |i| {
        if (result.types[i] == ctype) count += 1;
    }
    return count;
}

// ─── Differential Pair Test ─────────────────────────────────────────────────
//
// Two NMOS transistors:
//   D0: gate=N0(INP), drain=N2(diff_a), source=N4(tail), body=N5(VSS)
//   D1: gate=N1(INN), drain=N3(diff_b), source=N4(tail), body=N5(VSS)
//
// Same type (nmos), same W/L, shared source (N4), different gates (N0 != N1).
// Expected: 1 symmetry constraint.

test "differential pair produces 1 symmetry constraint" {
    const alloc = std.testing.allocator;

    // 2 devices, 6 nets, 8 pins.
    var devices = try DeviceArrays.init(alloc, 2);
    defer devices.deinit();
    devices.types[0] = .nmos;
    devices.types[1] = .nmos;
    devices.params[0] = .{ .w = 2.0e-6, .l = 0.13e-6, .fingers = 1, .mult = 1, .value = 0.0 };
    devices.params[1] = .{ .w = 2.0e-6, .l = 0.13e-6, .fingers = 1, .mult = 1, .value = 0.0 };

    var pins = try PinEdgeArrays.init(alloc, 8);
    defer pins.deinit();
    //                        base  dev  gate drain source body
    setMosfetPins(&pins, 0, 0, 0, 2, 4, 5); // D0
    setMosfetPins(&pins, 4, 1, 1, 3, 4, 5); // D1

    var adj = try FlatAdjList.buildFromSlices(alloc, 2, 6, 8, pins.device, pins.net);
    defer adj.deinit();

    var nets = try makeNets(alloc, 6, &.{});
    defer nets.deinit();

    var result = try extract.extractConstraints(alloc, &devices, &nets, &pins, &adj);
    defer result.deinit();

    // Exactly 1 symmetry constraint.
    try std.testing.expectEqual(@as(u32, 1), countConstraintsOfType(&result, .symmetry));

    // Verify device indices and weight.
    try std.testing.expectEqual(DeviceIdx.fromInt(0), result.device_a[0]);
    try std.testing.expectEqual(DeviceIdx.fromInt(1), result.device_b[0]);
    try std.testing.expectEqual(@as(f32, 1.0), result.weight[0]);
    try std.testing.expectEqual(ConstraintType.symmetry, result.types[0]);
}

// ─── Current Mirror Test ────────────────────────────────────────────────────
//
// Two NMOS transistors:
//   D0: gate=N0(bias), drain=N0(bias),  source=N2(VSS), body=N3(VSS)  (diode-connected)
//   D1: gate=N0(bias), drain=N1(out),   source=N2(VSS), body=N3(VSS)
//
// Same type, shared gate (N0), D0 is diode-connected (gate==drain==N0).
// Expected: 1 matching constraint.

test "current mirror produces 1 matching constraint" {
    const alloc = std.testing.allocator;

    var devices = try DeviceArrays.init(alloc, 2);
    defer devices.deinit();
    devices.types[0] = .nmos;
    devices.types[1] = .nmos;
    devices.params[0] = .{ .w = 4.0e-6, .l = 0.5e-6, .fingers = 1, .mult = 1, .value = 0.0 };
    devices.params[1] = .{ .w = 4.0e-6, .l = 0.5e-6, .fingers = 1, .mult = 1, .value = 0.0 };

    var pins = try PinEdgeArrays.init(alloc, 8);
    defer pins.deinit();
    //                   base  dev  gate drain source body
    // D0: diode-connected — gate and drain both on net 0
    setMosfetPins(&pins, 0, 0, 0, 0, 2, 3); // D0
    setMosfetPins(&pins, 4, 1, 0, 1, 2, 3); // D1

    var adj = try FlatAdjList.buildFromSlices(alloc, 2, 4, 8, pins.device, pins.net);
    defer adj.deinit();

    var nets = try makeNets(alloc, 4, &.{});
    defer nets.deinit();

    var result = try extract.extractConstraints(alloc, &devices, &nets, &pins, &adj);
    defer result.deinit();

    // Exactly 1 matching constraint.
    try std.testing.expectEqual(@as(u32, 1), countConstraintsOfType(&result, .matching));

    // Verify weight.
    // Find the matching constraint (it might not be at index 0 if other patterns also match).
    var found = false;
    for (0..result.len) |i| {
        if (result.types[i] == .matching) {
            try std.testing.expectEqual(@as(f32, 0.8), result.weight[i]);
            found = true;
            break;
        }
    }
    try std.testing.expect(found);
}

// ─── Cascode Test ───────────────────────────────────────────────────────────
//
// Two NMOS transistors:
//   D0: gate=N0, drain=N1(mid), source=N2(VSS), body=N3(VSS)
//   D1: gate=N4, drain=N5(out), source=N1(mid), body=N3(VSS)
//
// drain(D0) == N1 == source(D1)  →  drain-to-source chain.
// Expected: 1 proximity constraint.

test "cascode produces 1 proximity constraint" {
    const alloc = std.testing.allocator;

    var devices = try DeviceArrays.init(alloc, 2);
    defer devices.deinit();
    devices.types[0] = .nmos;
    devices.types[1] = .nmos;
    devices.params[0] = .{ .w = 2.0e-6, .l = 0.18e-6, .fingers = 1, .mult = 1, .value = 0.0 };
    devices.params[1] = .{ .w = 2.0e-6, .l = 0.18e-6, .fingers = 1, .mult = 1, .value = 0.0 };

    var pins = try PinEdgeArrays.init(alloc, 8);
    defer pins.deinit();
    //                   base  dev  gate drain source body
    setMosfetPins(&pins, 0, 0, 0, 1, 2, 3); // D0: drain=N1
    setMosfetPins(&pins, 4, 1, 4, 5, 1, 3); // D1: source=N1

    var adj = try FlatAdjList.buildFromSlices(alloc, 2, 6, 8, pins.device, pins.net);
    defer adj.deinit();

    var nets = try makeNets(alloc, 6, &.{});
    defer nets.deinit();

    var result = try extract.extractConstraints(alloc, &devices, &nets, &pins, &adj);
    defer result.deinit();

    // Exactly 1 proximity constraint.
    try std.testing.expectEqual(@as(u32, 1), countConstraintsOfType(&result, .proximity));

    // Verify the direction: device_a is the one whose drain feeds device_b's source.
    var found = false;
    for (0..result.len) |i| {
        if (result.types[i] == .proximity) {
            try std.testing.expectEqual(DeviceIdx.fromInt(0), result.device_a[i]);
            try std.testing.expectEqual(DeviceIdx.fromInt(1), result.device_b[i]);
            try std.testing.expectEqual(@as(f32, 0.5), result.weight[i]);
            found = true;
            break;
        }
    }
    try std.testing.expect(found);
}

// ─── No Constraints Test ────────────────────────────────────────────────────
//
// Two unrelated NMOS transistors with completely disjoint nets.
//   D0: gate=N0, drain=N1, source=N2, body=N3
//   D1: gate=N4, drain=N5, source=N6, body=N7
//
// No shared source, no shared gate, no drain-to-source chain.
// Expected: 0 constraints.

test "unrelated devices produce 0 constraints" {
    const alloc = std.testing.allocator;

    var devices = try DeviceArrays.init(alloc, 2);
    defer devices.deinit();
    devices.types[0] = .nmos;
    devices.types[1] = .nmos;
    devices.params[0] = .{ .w = 1.0e-6, .l = 0.18e-6, .fingers = 1, .mult = 1, .value = 0.0 };
    devices.params[1] = .{ .w = 1.0e-6, .l = 0.18e-6, .fingers = 1, .mult = 1, .value = 0.0 };

    var pins = try PinEdgeArrays.init(alloc, 8);
    defer pins.deinit();
    //                   base  dev  gate drain source body
    setMosfetPins(&pins, 0, 0, 0, 1, 2, 3); // D0: all unique nets
    setMosfetPins(&pins, 4, 1, 4, 5, 6, 7); // D1: all unique nets

    var adj = try FlatAdjList.buildFromSlices(alloc, 2, 8, 8, pins.device, pins.net);
    defer adj.deinit();

    var nets = try makeNets(alloc, 8, &.{});
    defer nets.deinit();

    var result = try extract.extractConstraints(alloc, &devices, &nets, &pins, &adj);
    defer result.deinit();

    try std.testing.expectEqual(@as(u32, 0), result.len);
}

// ─── Mixed-type devices do not match ────────────────────────────────────────
//
// One NMOS, one PMOS with otherwise identical connectivity pattern for
// a diff pair. Should produce 0 symmetry constraints because the device
// types differ.

test "diff pair pattern with different device types produces 0 symmetry" {
    const alloc = std.testing.allocator;

    var devices = try DeviceArrays.init(alloc, 2);
    defer devices.deinit();
    devices.types[0] = .nmos;
    devices.types[1] = .pmos; // different type!
    devices.params[0] = .{ .w = 2.0e-6, .l = 0.13e-6, .fingers = 1, .mult = 1, .value = 0.0 };
    devices.params[1] = .{ .w = 2.0e-6, .l = 0.13e-6, .fingers = 1, .mult = 1, .value = 0.0 };

    var pins = try PinEdgeArrays.init(alloc, 8);
    defer pins.deinit();
    setMosfetPins(&pins, 0, 0, 0, 2, 4, 5);
    setMosfetPins(&pins, 4, 1, 1, 3, 4, 5);

    var adj = try FlatAdjList.buildFromSlices(alloc, 2, 6, 8, pins.device, pins.net);
    defer adj.deinit();

    var nets = try makeNets(alloc, 6, &.{});
    defer nets.deinit();

    var result = try extract.extractConstraints(alloc, &devices, &nets, &pins, &adj);
    defer result.deinit();

    try std.testing.expectEqual(@as(u32, 0), countConstraintsOfType(&result, .symmetry));
}

// ─── Different W/L blocks diff-pair detection ───────────────────────────────

test "diff pair pattern with different W blocks symmetry" {
    const alloc = std.testing.allocator;

    var devices = try DeviceArrays.init(alloc, 2);
    defer devices.deinit();
    devices.types[0] = .nmos;
    devices.types[1] = .nmos;
    devices.params[0] = .{ .w = 2.0e-6, .l = 0.13e-6, .fingers = 1, .mult = 1, .value = 0.0 };
    devices.params[1] = .{ .w = 4.0e-6, .l = 0.13e-6, .fingers = 1, .mult = 1, .value = 0.0 }; // different W

    var pins = try PinEdgeArrays.init(alloc, 8);
    defer pins.deinit();
    setMosfetPins(&pins, 0, 0, 0, 2, 4, 5);
    setMosfetPins(&pins, 4, 1, 1, 3, 4, 5);

    var adj = try FlatAdjList.buildFromSlices(alloc, 2, 6, 8, pins.device, pins.net);
    defer adj.deinit();

    var nets = try makeNets(alloc, 6, &.{});
    defer nets.deinit();

    var result = try extract.extractConstraints(alloc, &devices, &nets, &pins, &adj);
    defer result.deinit();

    try std.testing.expectEqual(@as(u32, 0), countConstraintsOfType(&result, .symmetry));
}

// ─── Current mirror requires diode connection ───────────────────────────────

test "shared gate without diode connection produces 0 matching" {
    const alloc = std.testing.allocator;

    var devices = try DeviceArrays.init(alloc, 2);
    defer devices.deinit();
    devices.types[0] = .nmos;
    devices.types[1] = .nmos;
    devices.params[0] = .{ .w = 2.0e-6, .l = 0.5e-6, .fingers = 1, .mult = 1, .value = 0.0 };
    devices.params[1] = .{ .w = 2.0e-6, .l = 0.5e-6, .fingers = 1, .mult = 1, .value = 0.0 };

    var pins = try PinEdgeArrays.init(alloc, 8);
    defer pins.deinit();
    //                   base  dev  gate drain source body
    // Shared gate (N0), but neither is diode-connected (drains on different nets).
    setMosfetPins(&pins, 0, 0, 0, 1, 3, 4); // D0: gate=0, drain=1
    setMosfetPins(&pins, 4, 1, 0, 2, 3, 4); // D1: gate=0, drain=2

    var adj = try FlatAdjList.buildFromSlices(alloc, 2, 5, 8, pins.device, pins.net);
    defer adj.deinit();

    var nets = try makeNets(alloc, 5, &.{});
    defer nets.deinit();

    var result = try extract.extractConstraints(alloc, &devices, &nets, &pins, &adj);
    defer result.deinit();

    try std.testing.expectEqual(@as(u32, 0), countConstraintsOfType(&result, .matching));
}

// ─── Reverse cascode direction ──────────────────────────────────────────────

test "cascode detected in reverse direction" {
    const alloc = std.testing.allocator;

    // This time D1's drain feeds D0's source (the reverse of the main test).
    var devices = try DeviceArrays.init(alloc, 2);
    defer devices.deinit();
    devices.types[0] = .nmos;
    devices.types[1] = .nmos;
    devices.params[0] = .{ .w = 2.0e-6, .l = 0.18e-6, .fingers = 1, .mult = 1, .value = 0.0 };
    devices.params[1] = .{ .w = 2.0e-6, .l = 0.18e-6, .fingers = 1, .mult = 1, .value = 0.0 };

    var pins = try PinEdgeArrays.init(alloc, 8);
    defer pins.deinit();
    //                   base  dev  gate drain source body
    setMosfetPins(&pins, 0, 0, 0, 3, 1, 4); // D0: source=N1
    setMosfetPins(&pins, 4, 1, 5, 1, 2, 4); // D1: drain=N1

    // drain(D1)==N1 == source(D0)==N1 → cascode with D1 as "bottom", D0 as "top"
    var adj = try FlatAdjList.buildFromSlices(alloc, 2, 6, 8, pins.device, pins.net);
    defer adj.deinit();

    var nets = try makeNets(alloc, 6, &.{});
    defer nets.deinit();

    var result = try extract.extractConstraints(alloc, &devices, &nets, &pins, &adj);
    defer result.deinit();

    try std.testing.expectEqual(@as(u32, 1), countConstraintsOfType(&result, .proximity));

    // The device_a should be D1 (the one whose drain feeds) and device_b D0.
    for (0..result.len) |i| {
        if (result.types[i] == .proximity) {
            try std.testing.expectEqual(DeviceIdx.fromInt(1), result.device_a[i]);
            try std.testing.expectEqual(DeviceIdx.fromInt(0), result.device_b[i]);
        }
    }
}

// ─── Empty circuit ──────────────────────────────────────────────────────────

test "empty circuit produces 0 constraints" {
    const alloc = std.testing.allocator;

    var devices = try DeviceArrays.init(alloc, 0);
    defer devices.deinit();

    var pins = try PinEdgeArrays.init(alloc, 0);
    defer pins.deinit();

    var adj = try FlatAdjList.buildFromSlices(alloc, 0, 0, 0, pins.device, pins.net);
    defer adj.deinit();

    var nets = try makeNets(alloc, 0, &.{});
    defer nets.deinit();

    var result = try extract.extractConstraints(alloc, &devices, &nets, &pins, &adj);
    defer result.deinit();

    try std.testing.expectEqual(@as(u32, 0), result.len);
}

// ─── Single device ──────────────────────────────────────────────────────────

test "single device produces 0 constraints" {
    const alloc = std.testing.allocator;

    var devices = try DeviceArrays.init(alloc, 1);
    defer devices.deinit();
    devices.types[0] = .nmos;
    devices.params[0] = .{ .w = 2.0e-6, .l = 0.13e-6, .fingers = 1, .mult = 1, .value = 0.0 };

    var pins = try PinEdgeArrays.init(alloc, 4);
    defer pins.deinit();
    setMosfetPins(&pins, 0, 0, 0, 1, 2, 3);

    var adj = try FlatAdjList.buildFromSlices(alloc, 1, 4, 4, pins.device, pins.net);
    defer adj.deinit();

    var nets = try makeNets(alloc, 4, &.{});
    defer nets.deinit();

    var result = try extract.extractConstraints(alloc, &devices, &nets, &pins, &adj);
    defer result.deinit();

    try std.testing.expectEqual(@as(u32, 0), result.len);
}

// ─── Five-transistor OTA: diff pair + current mirror + cascode ──────────────
//
// M0 (NMOS): gate=INP(N0), drain=diff_a(N2), source=tail(N4), body=VSS(N5) — diff pair leg
// M1 (NMOS): gate=INN(N1), drain=diff_b(N3), source=tail(N4), body=VSS(N5) — diff pair leg
// M2 (PMOS): gate=VDD(N6), drain=diff_a(N2), source=VDD(N6), body=VDD(N6) — load (diode-connected: gate==source==VDD→ not diode as gate=drain)
// M3 (PMOS): gate=VDD(N6), drain=diff_b(N3), source=VDD(N6), body=VDD(N6) — load
// M4 (NMOS): gate=bias(N7), drain=tail(N4), source=VSS(N5), body=VSS(N5)  — tail bias
//
// Expected: M0+M1 form a differential pair (same type, same W/L, shared source=tail, different gates INP!=INN)
//   → 1 symmetry constraint with weight 1.0.
//
// M2+M3: same type (PMOS), shared gate (VDD=N6). M2 drain=N2, gate=N6, not diode. M3 drain=N3, gate=N6, not diode.
// Neither diode-connected → no current mirror. But they share gate and source, so check diff pair:
// Same type, same W/L, shared source (VDD), different drains. Gates are same (VDD) → NOT diff pair (gates same).
//
// M0,M4: drain(M4)=tail=N4 == source(M0)=tail=N4 → cascode!
// M1,M4: drain(M4)=tail=N4 == source(M1)=tail=N4 → cascode!

test "five-transistor OTA detects diff pair symmetry" {
    const alloc = std.testing.allocator;

    var devices = try DeviceArrays.init(alloc, 5);
    defer devices.deinit();

    // M0, M1: NMOS diff pair
    devices.types[0] = .nmos;
    devices.types[1] = .nmos;
    devices.params[0] = .{ .w = 2.0e-6, .l = 0.13e-6, .fingers = 1, .mult = 1, .value = 0.0 };
    devices.params[1] = .{ .w = 2.0e-6, .l = 0.13e-6, .fingers = 1, .mult = 1, .value = 0.0 };

    // M2, M3: PMOS loads
    devices.types[2] = .pmos;
    devices.types[3] = .pmos;
    devices.params[2] = .{ .w = 4.0e-6, .l = 0.13e-6, .fingers = 1, .mult = 1, .value = 0.0 };
    devices.params[3] = .{ .w = 4.0e-6, .l = 0.13e-6, .fingers = 1, .mult = 1, .value = 0.0 };

    // M4: NMOS tail bias
    devices.types[4] = .nmos;
    devices.params[4] = .{ .w = 4.0e-6, .l = 0.13e-6, .fingers = 1, .mult = 1, .value = 0.0 };

    var pins = try PinEdgeArrays.init(alloc, 20);
    defer pins.deinit();

    // Nets: 0=INP, 1=INN, 2=diff_a, 3=diff_b, 4=tail, 5=VSS, 6=VDD, 7=bias
    setMosfetPins(&pins, 0, 0, 0, 2, 4, 5); // M0: gate=INP, drain=diff_a, source=tail, body=VSS
    setMosfetPins(&pins, 4, 1, 1, 3, 4, 5); // M1: gate=INN, drain=diff_b, source=tail, body=VSS
    setMosfetPins(&pins, 8, 2, 6, 2, 6, 6); // M2: gate=VDD, drain=diff_a, source=VDD, body=VDD
    setMosfetPins(&pins, 12, 3, 6, 3, 6, 6); // M3: gate=VDD, drain=diff_b, source=VDD, body=VDD
    setMosfetPins(&pins, 16, 4, 7, 4, 5, 5); // M4: gate=bias, drain=tail, source=VSS, body=VSS

    var adj = try FlatAdjList.buildFromSlices(alloc, 5, 8, 20, pins.device, pins.net);
    defer adj.deinit();

    // N4=tail (not a rail), N5=VSS (rail), N6=VDD (rail)
    var nets = try makeNets(alloc, 8, &.{ 5, 6 });
    defer nets.deinit();

    var result = try extract.extractConstraints(alloc, &devices, &nets, &pins, &adj);
    defer result.deinit();

    // Should detect at least 1 symmetry constraint (M0, M1 diff pair)
    try std.testing.expect(countConstraintsOfType(&result, .symmetry) >= 1);

    // Should detect cascode constraints (M0-M4, M1-M4)
    try std.testing.expect(countConstraintsOfType(&result, .proximity) >= 2);
}

// ─── Current mirror with 3 devices ──────────────────────────────────────────
//
// M0: gate=N0(bias), drain=N0(bias), source=N1(VSS), body=N1(VSS) — diode-connected
// M1: gate=N0(bias), drain=N2(out1), source=N1(VSS), body=N1(VSS) — mirror copy 1
// M2: gate=N0(bias), drain=N3(out2), source=N1(VSS), body=N1(VSS) — mirror copy 2
//
// All pairs (M0,M1), (M0,M2), (M1,M2) share gate N0.
// M0 is diode-connected (gate=drain=N0).
// Expected: 3 matching constraints (one for each pair).

test "current mirror with 3 devices produces multiple matching constraints" {
    const alloc = std.testing.allocator;

    var devices = try DeviceArrays.init(alloc, 3);
    defer devices.deinit();
    devices.types[0] = .nmos;
    devices.types[1] = .nmos;
    devices.types[2] = .nmos;
    const p = DeviceParams{ .w = 2.0e-6, .l = 0.5e-6, .fingers = 1, .mult = 1, .value = 0.0 };
    devices.params[0] = p;
    devices.params[1] = p;
    devices.params[2] = p;

    var pins = try PinEdgeArrays.init(alloc, 12);
    defer pins.deinit();

    // M0: diode-connected (gate=N0, drain=N0)
    setMosfetPins(&pins, 0, 0, 0, 0, 1, 1); // gate=0, drain=0, source=1, body=1
    // M1: mirror copy
    setMosfetPins(&pins, 4, 1, 0, 2, 1, 1); // gate=0, drain=2, source=1, body=1
    // M2: mirror copy
    setMosfetPins(&pins, 8, 2, 0, 3, 1, 1); // gate=0, drain=3, source=1, body=1

    var adj = try FlatAdjList.buildFromSlices(alloc, 3, 4, 12, pins.device, pins.net);
    defer adj.deinit();

    var nets = try makeNets(alloc, 4, &.{});
    defer nets.deinit();

    var result = try extract.extractConstraints(alloc, &devices, &nets, &pins, &adj);
    defer result.deinit();

    // 3 pairs: (M0,M1), (M0,M2), (M1,M2) — all share gate, M0 is diode-connected
    const matching_count = countConstraintsOfType(&result, .matching);
    try std.testing.expect(matching_count >= 2);

    // All matching constraints should have weight 0.8
    for (0..result.len) |i| {
        if (result.types[i] == .matching) {
            try std.testing.expectEqual(@as(f32, 0.8), result.weight[i]);
        }
    }
}

// ─── Cascode pair + diff pair circuit ────────────────────────────────────────
//
// M0, M1: diff pair (shared source on N4, different gates N0 and N1)
// M2: cascode on M0 (drain(M0)=source(M2)=N2)
// M3: cascode on M1 (drain(M1)=source(M3)=N3)

test "circuit with cascode pair and diff pair finds both proximity and symmetry" {
    const alloc = std.testing.allocator;

    var devices = try DeviceArrays.init(alloc, 4);
    defer devices.deinit();

    const nmos_params = DeviceParams{ .w = 2.0e-6, .l = 0.18e-6, .fingers = 1, .mult = 1, .value = 0.0 };
    for (0..4) |i| {
        devices.types[i] = .nmos;
        devices.params[i] = nmos_params;
    }

    var pins = try PinEdgeArrays.init(alloc, 16);
    defer pins.deinit();

    // M0: gate=N0, drain=N2, source=N4, body=N5
    setMosfetPins(&pins, 0, 0, 0, 2, 4, 5);
    // M1: gate=N1, drain=N3, source=N4, body=N5
    setMosfetPins(&pins, 4, 1, 1, 3, 4, 5);
    // M2: gate=N6, drain=N7, source=N2, body=N5 (cascode on M0: source(M2)=drain(M0)=N2)
    setMosfetPins(&pins, 8, 2, 6, 7, 2, 5);
    // M3: gate=N8, drain=N9, source=N3, body=N5 (cascode on M1: source(M3)=drain(M1)=N3)
    setMosfetPins(&pins, 12, 3, 8, 9, 3, 5);

    var adj = try FlatAdjList.buildFromSlices(alloc, 4, 10, 16, pins.device, pins.net);
    defer adj.deinit();

    var nets = try makeNets(alloc, 10, &.{});
    defer nets.deinit();

    var result = try extract.extractConstraints(alloc, &devices, &nets, &pins, &adj);
    defer result.deinit();

    // Should find symmetry (M0-M1 diff pair)
    try std.testing.expect(countConstraintsOfType(&result, .symmetry) >= 1);

    // Should find proximity (cascode: M0-M2 and M1-M3)
    try std.testing.expect(countConstraintsOfType(&result, .proximity) >= 2);
}

// ─── No-pattern circuit ─────────────────────────────────────────────────────

test "no-pattern circuit with random unrelated devices produces 0 constraints" {
    const alloc = std.testing.allocator;

    // 4 devices, all different types, no shared nets
    var devices = try DeviceArrays.init(alloc, 4);
    defer devices.deinit();

    devices.types[0] = .nmos;
    devices.types[1] = .pmos; // different type from D0
    devices.types[2] = .nmos;
    devices.types[3] = .nmos;

    // Give different W/L to prevent diff pair matching even for same-type pairs
    devices.params[0] = .{ .w = 1.0e-6, .l = 0.13e-6, .fingers = 1, .mult = 1, .value = 0.0 };
    devices.params[1] = .{ .w = 2.0e-6, .l = 0.25e-6, .fingers = 1, .mult = 1, .value = 0.0 };
    devices.params[2] = .{ .w = 3.0e-6, .l = 0.50e-6, .fingers = 1, .mult = 1, .value = 0.0 };
    devices.params[3] = .{ .w = 4.0e-6, .l = 1.00e-6, .fingers = 1, .mult = 1, .value = 0.0 };

    var pins = try PinEdgeArrays.init(alloc, 16);
    defer pins.deinit();

    // All on completely separate nets (no shared connectivity)
    setMosfetPins(&pins, 0, 0, 0, 1, 2, 3);
    setMosfetPins(&pins, 4, 1, 4, 5, 6, 7);
    setMosfetPins(&pins, 8, 2, 8, 9, 10, 11);
    setMosfetPins(&pins, 12, 3, 12, 13, 14, 15);

    var adj = try FlatAdjList.buildFromSlices(alloc, 4, 16, 16, pins.device, pins.net);
    defer adj.deinit();

    var nets = try makeNets(alloc, 16, &.{});
    defer nets.deinit();

    var result = try extract.extractConstraints(alloc, &devices, &nets, &pins, &adj);
    defer result.deinit();

    try std.testing.expectEqual(@as(u32, 0), result.len);
}

// ─── Constraint weight values ───────────────────────────────────────────────

test "symmetry weight is 1.0, matching is 0.8, proximity is 0.5" {
    const alloc = std.testing.allocator;

    // Create a circuit that triggers all three constraint types:
    // Diff pair (symmetry), current mirror (matching), cascode (proximity)

    var devices = try DeviceArrays.init(alloc, 4);
    defer devices.deinit();

    const nmos_p = DeviceParams{ .w = 2.0e-6, .l = 0.13e-6, .fingers = 1, .mult = 1, .value = 0.0 };
    for (0..4) |i| {
        devices.types[i] = .nmos;
        devices.params[i] = nmos_p;
    }

    var pins = try PinEdgeArrays.init(alloc, 16);
    defer pins.deinit();

    // M0, M1: diff pair (shared source N4, different gates N0, N1)
    setMosfetPins(&pins, 0, 0, 0, 2, 4, 5); // gate=0, drain=2, source=4
    setMosfetPins(&pins, 4, 1, 1, 3, 4, 5); // gate=1, drain=3, source=4

    // M2: diode-connected, shares gate with M3 → current mirror
    setMosfetPins(&pins, 8, 2, 6, 6, 7, 5); // gate=6, drain=6 (diode-connected), source=7

    // M3: mirror of M2
    setMosfetPins(&pins, 12, 3, 6, 8, 7, 5); // gate=6, drain=8, source=7

    var adj = try FlatAdjList.buildFromSlices(alloc, 4, 9, 16, pins.device, pins.net);
    defer adj.deinit();

    var nets = try makeNets(alloc, 9, &.{});
    defer nets.deinit();

    var result = try extract.extractConstraints(alloc, &devices, &nets, &pins, &adj);
    defer result.deinit();

    // Verify weight values for each constraint type
    for (0..result.len) |i| {
        switch (result.types[i]) {
            .symmetry => try std.testing.expectEqual(@as(f32, 1.0), result.weight[i]),
            .matching => try std.testing.expectEqual(@as(f32, 0.8), result.weight[i]),
            .proximity => try std.testing.expectEqual(@as(f32, 0.5), result.weight[i]),
            .isolation => {},
        }
    }

    // Should have at least one of each triggered type
    try std.testing.expect(countConstraintsOfType(&result, .symmetry) >= 1);
    try std.testing.expect(countConstraintsOfType(&result, .matching) >= 1);
}

// ─── isSeedPair: rail detection and effective-W via fingers ─────────────────

test "diff pair: shared source NOT a rail → 1 symmetry with group_id=1" {
    const alloc = std.testing.allocator;
    var devices = try DeviceArrays.init(alloc, 2);
    defer devices.deinit();
    devices.types[0] = .nmos; devices.types[1] = .nmos;
    devices.params[0] = .{ .w = 2.0e-6, .l = 0.13e-6, .fingers = 1, .mult = 1, .value = 0.0 };
    devices.params[1] = .{ .w = 2.0e-6, .l = 0.13e-6, .fingers = 1, .mult = 1, .value = 0.0 };

    var pins = try PinEdgeArrays.init(alloc, 8);
    defer pins.deinit();
    // D0: gate=N0, drain=N2, source=N4(tail), body=N5(vss)
    // D1: gate=N1, drain=N3, source=N4(tail), body=N5(vss)
    setMosfetPins(&pins, 0, 0, 0, 2, 4, 5);
    setMosfetPins(&pins, 4, 1, 1, 3, 4, 5);

    var adj = try FlatAdjList.buildFromSlices(alloc, 2, 6, 8, pins.device, pins.net);
    defer adj.deinit();
    // N5 is VSS (rail), N4 is tail (NOT rail)
    var nets = try makeNets(alloc, 6, &.{5});
    defer nets.deinit();

    var result = try extract.extractConstraints(alloc, &devices, &nets, &pins, &adj);
    defer result.deinit();

    try std.testing.expectEqual(@as(u32, 1), countConstraintsOfType(&result, .symmetry));
    try std.testing.expectEqual(@as(u32, 1), result.group_id[0]);
}

test "diff pair blocked: shared source IS a rail → 0 symmetry" {
    const alloc = std.testing.allocator;
    var devices = try DeviceArrays.init(alloc, 2);
    defer devices.deinit();
    devices.types[0] = .nmos; devices.types[1] = .nmos;
    devices.params[0] = .{ .w = 2.0e-6, .l = 0.13e-6, .fingers = 1, .mult = 1, .value = 0.0 };
    devices.params[1] = .{ .w = 2.0e-6, .l = 0.13e-6, .fingers = 1, .mult = 1, .value = 0.0 };

    var pins = try PinEdgeArrays.init(alloc, 8);
    defer pins.deinit();
    setMosfetPins(&pins, 0, 0, 0, 2, 4, 5);
    setMosfetPins(&pins, 4, 1, 1, 3, 4, 5);

    var adj = try FlatAdjList.buildFromSlices(alloc, 2, 6, 8, pins.device, pins.net);
    defer adj.deinit();
    var nets = try makeNets(alloc, 6, &.{ 4, 5 }); // N4 IS a rail
    defer nets.deinit();

    var result = try extract.extractConstraints(alloc, &devices, &nets, &pins, &adj);
    defer result.deinit();

    try std.testing.expectEqual(@as(u32, 0), countConstraintsOfType(&result, .symmetry));
}

test "diff pair: effective W match via fingers → 1 symmetry" {
    const alloc = std.testing.allocator;
    var devices = try DeviceArrays.init(alloc, 2);
    defer devices.deinit();
    devices.types[0] = .nmos; devices.types[1] = .nmos;
    // D0: W=1µm, fingers=4 → effective=4µm
    devices.params[0] = .{ .w = 1.0e-6, .l = 0.13e-6, .fingers = 4, .mult = 1, .value = 0.0 };
    // D1: W=2µm, fingers=2 → effective=4µm
    devices.params[1] = .{ .w = 2.0e-6, .l = 0.13e-6, .fingers = 2, .mult = 1, .value = 0.0 };

    var pins = try PinEdgeArrays.init(alloc, 8);
    defer pins.deinit();
    setMosfetPins(&pins, 0, 0, 0, 2, 4, 5);
    setMosfetPins(&pins, 4, 1, 1, 3, 4, 5);

    var adj = try FlatAdjList.buildFromSlices(alloc, 2, 6, 8, pins.device, pins.net);
    defer adj.deinit();
    var nets = try makeNets(alloc, 6, &.{5});
    defer nets.deinit();

    var result = try extract.extractConstraints(alloc, &devices, &nets, &pins, &adj);
    defer result.deinit();

    try std.testing.expectEqual(@as(u32, 1), countConstraintsOfType(&result, .symmetry));
}

test "diff pair: effective W match via mult → 1 symmetry" {
    const alloc = std.testing.allocator;
    var devices = try DeviceArrays.init(alloc, 2);
    defer devices.deinit();
    devices.types[0] = .nmos; devices.types[1] = .nmos;
    // D0: W=2µm, mult=2 → effective=4µm
    devices.params[0] = .{ .w = 2.0e-6, .l = 0.13e-6, .fingers = 1, .mult = 2, .value = 0.0 };
    // D1: W=1µm, fingers=4 → effective=4µm
    devices.params[1] = .{ .w = 1.0e-6, .l = 0.13e-6, .fingers = 4, .mult = 1, .value = 0.0 };

    var pins = try PinEdgeArrays.init(alloc, 8);
    defer pins.deinit();
    setMosfetPins(&pins, 0, 0, 0, 2, 4, 5);
    setMosfetPins(&pins, 4, 1, 1, 3, 4, 5);

    var adj = try FlatAdjList.buildFromSlices(alloc, 2, 6, 8, pins.device, pins.net);
    defer adj.deinit();
    var nets = try makeNets(alloc, 6, &.{5});
    defer nets.deinit();

    var result = try extract.extractConstraints(alloc, &devices, &nets, &pins, &adj);
    defer result.deinit();

    try std.testing.expectEqual(@as(u32, 1), countConstraintsOfType(&result, .symmetry));
}

test "diff pair: mismatched effective W (mult differs) → 0 symmetry" {
    const alloc = std.testing.allocator;
    var devices = try DeviceArrays.init(alloc, 2);
    defer devices.deinit();
    devices.types[0] = .nmos; devices.types[1] = .nmos;
    // D0: W=2µm, mult=1 → effective=2µm
    devices.params[0] = .{ .w = 2.0e-6, .l = 0.13e-6, .fingers = 1, .mult = 1, .value = 0.0 };
    // D1: W=2µm, mult=2 → effective=4µm (mismatch)
    devices.params[1] = .{ .w = 2.0e-6, .l = 0.13e-6, .fingers = 1, .mult = 2, .value = 0.0 };

    var pins = try PinEdgeArrays.init(alloc, 8);
    defer pins.deinit();
    setMosfetPins(&pins, 0, 0, 0, 2, 4, 5);
    setMosfetPins(&pins, 4, 1, 1, 3, 4, 5);

    var adj = try FlatAdjList.buildFromSlices(alloc, 2, 6, 8, pins.device, pins.net);
    defer adj.deinit();
    var nets = try makeNets(alloc, 6, &.{5});
    defer nets.deinit();

    var result = try extract.extractConstraints(alloc, &devices, &nets, &pins, &adj);
    defer result.deinit();

    try std.testing.expectEqual(@as(u32, 0), countConstraintsOfType(&result, .symmetry));
}

// ─── 5T OTA load pair traversal ─────────────────────────────────────────────
//
// 5-transistor OTA with cross-coupled PMOS load:
//   mn2 (NMOS): gate=vin(N0), drain=von(N2), source=tail(N4), body=vss(N5)
//   mn3 (NMOS): gate=vip(N1), drain=vop(N3), source=tail(N4), body=vss(N5)
//   mp4 (PMOS): gate=vop(N3), drain=von(N2), source=vdd(N6), body=vdd(N6)
//   mp5 (PMOS): gate=vop(N3), drain=vop(N3), source=vdd(N6), body=vdd(N6) (diode)
//   mn1 (NMOS): gate=bias(N7), drain=tail(N4), source=vss(N5), body=vss(N5)
//
// Expected:
//   - mn2↔mn3 detected as diff pair symmetry (group_id = some non-zero value)
//   - mp4↔mp5 detected as load pair symmetry (same group_id as diff pair)

test "5T OTA: load pair mp4+mp5 detected as symmetry in group 1" {
    const alloc = std.testing.allocator;

    var devices = try DeviceArrays.init(alloc, 5);
    defer devices.deinit();
    devices.types[0] = .nmos; // mn2
    devices.types[1] = .nmos; // mn3
    devices.types[2] = .pmos; // mp4
    devices.types[3] = .pmos; // mp5
    devices.types[4] = .nmos; // mn1 tail
    const nmos_p = DeviceParams{ .w = 2.0e-6, .l = 0.13e-6, .fingers = 1, .mult = 1, .value = 0.0 };
    const pmos_p = DeviceParams{ .w = 4.0e-6, .l = 0.13e-6, .fingers = 1, .mult = 1, .value = 0.0 };
    devices.params[0] = nmos_p; devices.params[1] = nmos_p;
    devices.params[2] = pmos_p; devices.params[3] = pmos_p;
    devices.params[4] = .{ .w = 4.0e-6, .l = 0.13e-6, .fingers = 1, .mult = 1, .value = 0.0 };

    // Nets: 0=vin, 1=vip, 2=von, 3=vop, 4=tail, 5=vss, 6=vdd, 7=bias
    var pins = try PinEdgeArrays.init(alloc, 20);
    defer pins.deinit();
    setMosfetPins(&pins, 0,  0, 0, 2, 4, 5); // mn2: gate=vin,drain=von,src=tail,body=vss
    setMosfetPins(&pins, 4,  1, 1, 3, 4, 5); // mn3: gate=vip,drain=vop,src=tail,body=vss
    setMosfetPins(&pins, 8,  2, 3, 2, 6, 6); // mp4: gate=vop,drain=von,src=vdd,body=vdd
    setMosfetPins(&pins, 12, 3, 3, 3, 6, 6); // mp5: gate=vop,drain=vop,src=vdd,body=vdd (diode)
    setMosfetPins(&pins, 16, 4, 7, 4, 5, 5); // mn1: gate=bias,drain=tail,src=vss,body=vss

    var adj = try FlatAdjList.buildFromSlices(alloc, 5, 8, 20, pins.device, pins.net);
    defer adj.deinit();
    var nets = try NetArrays.init(alloc, 8);
    defer nets.deinit();
    nets.is_power[5] = true; // vss
    nets.is_power[6] = true; // vdd

    var result = try extract.extractConstraints(alloc, &devices, &nets, &pins, &adj);
    defer result.deinit();

    // mn2↔mn3: symmetry, plus mp4↔mp5 load pair
    try std.testing.expect(countConstraintsOfType(&result, .symmetry) >= 2);
    // mp4↔mp5 load pair must also be in the result
    var found_load = false;
    for (0..result.len) |i| {
        if (result.types[i] == .symmetry) {
            const a = result.device_a[i].toInt();
            const b = result.device_b[i].toInt();
            if ((a == 2 and b == 3) or (a == 3 and b == 2)) { found_load = true; break; }
        }
    }
    try std.testing.expect(found_load);
    // Load pair must share group_id with the diff pair
    var diff_gid: u32 = 0;
    var load_gid: u32 = 0;
    for (0..result.len) |i| {
        if (result.types[i] == .symmetry and result.device_a[i].toInt() == 0) diff_gid = result.group_id[i];
        if (result.types[i] == .symmetry and result.device_a[i].toInt() == 2) load_gid = result.group_id[i];
    }
    try std.testing.expect(diff_gid != 0);
    try std.testing.expectEqual(diff_gid, load_gid);
}

// ─── 5T OTA tail bias: self-symmetric constraint ─────────────────────────────
//
// Same 5T OTA circuit as above. mn1 (device 4) is the tail bias transistor:
//   mn1 (NMOS): gate=bias(N7), drain=tail(N4), source=vss(N5), body=vss(N5)
//
// mn1's drain connects to the diff pair's shared source (tail=N4), and its
// source connects to VSS (a rail). It has no symmetric partner, so it should
// be detected as a self-symmetric device within the same group as the diff pair.
//
// Expected: a symmetry constraint with device_a == device_b == 4, group_id != 0.

// ─── Current mirror: effective-W matching and ratio mirrors ─────────────────

test "current mirror 1:1 with different fingers but same effective W → matching" {
    const alloc = std.testing.allocator;
    var devices = try DeviceArrays.init(alloc, 2);
    defer devices.deinit();
    devices.types[0] = .nmos; devices.types[1] = .nmos;
    // D0: W=2µm, fingers=1 → effective=2µm  (diode-connected)
    devices.params[0] = .{ .w = 2.0e-6, .l = 0.5e-6, .fingers = 1, .mult = 1, .value = 0.0 };
    // D1: W=1µm, fingers=2 → effective=2µm
    devices.params[1] = .{ .w = 1.0e-6, .l = 0.5e-6, .fingers = 2, .mult = 1, .value = 0.0 };

    var pins = try PinEdgeArrays.init(alloc, 8);
    defer pins.deinit();
    setMosfetPins(&pins, 0, 0, 0, 0, 2, 3); // D0: gate=0, drain=0 (diode), src=2, body=3
    setMosfetPins(&pins, 4, 1, 0, 1, 2, 3); // D1: gate=0, drain=1, src=2, body=3

    var adj = try FlatAdjList.buildFromSlices(alloc, 2, 4, 8, pins.device, pins.net);
    defer adj.deinit();
    var nets = try NetArrays.init(alloc, 4);
    defer nets.deinit();
    nets.is_power[2] = true; // VSS

    var result = try extract.extractConstraints(alloc, &devices, &nets, &pins, &adj);
    defer result.deinit();

    try std.testing.expectEqual(@as(u32, 1), countConstraintsOfType(&result, .matching));
    try std.testing.expectApproxEqAbs(@as(f32, 0.8), result.weight[0], 1e-6);
}

test "ratio mirror 1:2 → matching with weight 0.7" {
    const alloc = std.testing.allocator;
    var devices = try DeviceArrays.init(alloc, 2);
    defer devices.deinit();
    devices.types[0] = .nmos; devices.types[1] = .nmos;
    // D0: W=2µm, fingers=1 → effective=2µm  (diode-connected, reference)
    devices.params[0] = .{ .w = 2.0e-6, .l = 0.5e-6, .fingers = 1, .mult = 1, .value = 0.0 };
    // D1: W=4µm, fingers=1 → effective=4µm  (2x mirror output)
    devices.params[1] = .{ .w = 4.0e-6, .l = 0.5e-6, .fingers = 1, .mult = 1, .value = 0.0 };

    var pins = try PinEdgeArrays.init(alloc, 8);
    defer pins.deinit();
    setMosfetPins(&pins, 0, 0, 0, 0, 2, 3); // D0: diode-connected
    setMosfetPins(&pins, 4, 1, 0, 1, 2, 3); // D1: mirror output

    var adj = try FlatAdjList.buildFromSlices(alloc, 2, 4, 8, pins.device, pins.net);
    defer adj.deinit();
    var nets = try NetArrays.init(alloc, 4);
    defer nets.deinit();
    nets.is_power[2] = true;

    var result = try extract.extractConstraints(alloc, &devices, &nets, &pins, &adj);
    defer result.deinit();

    try std.testing.expectEqual(@as(u32, 1), countConstraintsOfType(&result, .matching));
    try std.testing.expectApproxEqAbs(@as(f32, 0.7), result.weight[0], 1e-6);
}

test "ratio 1:9 (out of range) → 0 matching" {
    const alloc = std.testing.allocator;
    var devices = try DeviceArrays.init(alloc, 2);
    defer devices.deinit();
    devices.types[0] = .nmos; devices.types[1] = .nmos;
    devices.params[0] = .{ .w = 1.0e-6, .l = 0.5e-6, .fingers = 1, .mult = 1, .value = 0.0 };
    devices.params[1] = .{ .w = 9.0e-6, .l = 0.5e-6, .fingers = 1, .mult = 1, .value = 0.0 };

    var pins = try PinEdgeArrays.init(alloc, 8);
    defer pins.deinit();
    setMosfetPins(&pins, 0, 0, 0, 0, 2, 3);
    setMosfetPins(&pins, 4, 1, 0, 1, 2, 3);

    var adj = try FlatAdjList.buildFromSlices(alloc, 2, 4, 8, pins.device, pins.net);
    defer adj.deinit();
    var nets = try NetArrays.init(alloc, 4);
    defer nets.deinit();
    nets.is_power[2] = true;

    var result = try extract.extractConstraints(alloc, &devices, &nets, &pins, &adj);
    defer result.deinit();

    try std.testing.expectEqual(@as(u32, 0), countConstraintsOfType(&result, .matching));
}

// ─── Passive pair helpers ────────────────────────────────────────────────────

/// Populate two passive pins (anode + cathode) for a device,
/// starting at pin index `base`.
fn setPassivePins(
    pins: *PinEdgeArrays,
    base: usize,
    device: u32,
    anode_net: u32,
    cathode_net: u32,
) void {
    const d = DeviceIdx.fromInt(device);

    pins.device[base + 0] = d;
    pins.net[base + 0] = NetIdx.fromInt(anode_net);
    pins.terminal[base + 0] = .anode;

    pins.device[base + 1] = d;
    pins.net[base + 1] = NetIdx.fromInt(cathode_net);
    pins.terminal[base + 1] = .cathode;
}

// ─── Passive pair tests ──────────────────────────────────────────────────────

// Two resistors with same value → 1 matching constraint, weight 0.7.
test "resistor pair same value produces 1 matching constraint with weight 0.7" {
    const alloc = std.testing.allocator;

    var devices = try DeviceArrays.init(alloc, 2);
    defer devices.deinit();
    devices.types[0] = .res;
    devices.types[1] = .res;
    devices.params[0] = .{ .w = 0.0, .l = 0.0, .fingers = 1, .mult = 1, .value = 1000.0 };
    devices.params[1] = .{ .w = 0.0, .l = 0.0, .fingers = 1, .mult = 1, .value = 1000.0 };

    // 4 pins total: 2 per device, each on its own net (0,1 for D0; 2,3 for D1)
    var pins = try PinEdgeArrays.init(alloc, 4);
    defer pins.deinit();
    setPassivePins(&pins, 0, 0, 0, 1); // D0: anode=N0, cathode=N1
    setPassivePins(&pins, 2, 1, 2, 3); // D1: anode=N2, cathode=N3

    var adj = try FlatAdjList.buildFromSlices(alloc, 2, 4, 4, pins.device, pins.net);
    defer adj.deinit();

    var nets = try makeNets(alloc, 4, &.{});
    defer nets.deinit();

    var result = try extract.extractConstraints(alloc, &devices, &nets, &pins, &adj);
    defer result.deinit();

    try std.testing.expectEqual(@as(u32, 1), countConstraintsOfType(&result, .matching));
    var found = false;
    for (0..result.len) |i| {
        if (result.types[i] == .matching) {
            try std.testing.expectApproxEqAbs(@as(f32, 0.7), result.weight[i], 1e-6);
            found = true;
            break;
        }
    }
    try std.testing.expect(found);
}

// Two capacitors with same value → 1 matching constraint.
test "capacitor pair same value produces 1 matching constraint" {
    const alloc = std.testing.allocator;

    var devices = try DeviceArrays.init(alloc, 2);
    defer devices.deinit();
    devices.types[0] = .cap;
    devices.types[1] = .cap;
    devices.params[0] = .{ .w = 0.0, .l = 0.0, .fingers = 1, .mult = 1, .value = 1.0e-12 };
    devices.params[1] = .{ .w = 0.0, .l = 0.0, .fingers = 1, .mult = 1, .value = 1.0e-12 };

    var pins = try PinEdgeArrays.init(alloc, 4);
    defer pins.deinit();
    setPassivePins(&pins, 0, 0, 0, 1); // D0: anode=N0, cathode=N1
    setPassivePins(&pins, 2, 1, 2, 3); // D1: anode=N2, cathode=N3

    var adj = try FlatAdjList.buildFromSlices(alloc, 2, 4, 4, pins.device, pins.net);
    defer adj.deinit();

    var nets = try makeNets(alloc, 4, &.{});
    defer nets.deinit();

    var result = try extract.extractConstraints(alloc, &devices, &nets, &pins, &adj);
    defer result.deinit();

    try std.testing.expectEqual(@as(u32, 1), countConstraintsOfType(&result, .matching));
}

// Two resistors with different values → 0 matching constraints.
test "resistor pair different values produces 0 matching constraints" {
    const alloc = std.testing.allocator;

    var devices = try DeviceArrays.init(alloc, 2);
    defer devices.deinit();
    devices.types[0] = .res;
    devices.types[1] = .res;
    devices.params[0] = .{ .w = 0.0, .l = 0.0, .fingers = 1, .mult = 1, .value = 1000.0 };
    devices.params[1] = .{ .w = 0.0, .l = 0.0, .fingers = 1, .mult = 1, .value = 2000.0 };

    var pins = try PinEdgeArrays.init(alloc, 4);
    defer pins.deinit();
    setPassivePins(&pins, 0, 0, 0, 1); // D0: anode=N0, cathode=N1
    setPassivePins(&pins, 2, 1, 2, 3); // D1: anode=N2, cathode=N3

    var adj = try FlatAdjList.buildFromSlices(alloc, 2, 4, 4, pins.device, pins.net);
    defer adj.deinit();

    var nets = try makeNets(alloc, 4, &.{});
    defer nets.deinit();

    var result = try extract.extractConstraints(alloc, &devices, &nets, &pins, &adj);
    defer result.deinit();

    try std.testing.expectEqual(@as(u32, 0), countConstraintsOfType(&result, .matching));
}

test "5T OTA: tail bias mn1 is self-symmetric in group 1" {
    const alloc = std.testing.allocator;

    var devices = try DeviceArrays.init(alloc, 5);
    defer devices.deinit();
    devices.types[0] = .nmos; // mn2
    devices.types[1] = .nmos; // mn3
    devices.types[2] = .pmos; // mp4
    devices.types[3] = .pmos; // mp5
    devices.types[4] = .nmos; // mn1 tail
    devices.params[0] = .{ .w = 2.0e-6, .l = 0.13e-6, .fingers = 1, .mult = 1, .value = 0.0 };
    devices.params[1] = .{ .w = 2.0e-6, .l = 0.13e-6, .fingers = 1, .mult = 1, .value = 0.0 };
    devices.params[2] = .{ .w = 4.0e-6, .l = 0.13e-6, .fingers = 1, .mult = 1, .value = 0.0 };
    devices.params[3] = .{ .w = 4.0e-6, .l = 0.13e-6, .fingers = 1, .mult = 1, .value = 0.0 };
    devices.params[4] = .{ .w = 4.0e-6, .l = 0.13e-6, .fingers = 1, .mult = 1, .value = 0.0 };

    // Nets: 0=vin, 1=vip, 2=von, 3=vop, 4=tail, 5=vss, 6=vdd, 7=bias
    var pins = try PinEdgeArrays.init(alloc, 20);
    defer pins.deinit();
    setMosfetPins(&pins, 0,  0, 0, 2, 4, 5); // mn2: gate=vin,drain=von,src=tail,body=vss
    setMosfetPins(&pins, 4,  1, 1, 3, 4, 5); // mn3: gate=vip,drain=vop,src=tail,body=vss
    setMosfetPins(&pins, 8,  2, 3, 2, 6, 6); // mp4: gate=vop,drain=von,src=vdd,body=vdd
    setMosfetPins(&pins, 12, 3, 3, 3, 6, 6); // mp5: gate=vop,drain=vop,src=vdd,body=vdd
    setMosfetPins(&pins, 16, 4, 7, 4, 5, 5); // mn1: gate=bias,drain=tail,src=vss,body=vss

    var adj = try FlatAdjList.buildFromSlices(alloc, 5, 8, 20, pins.device, pins.net);
    defer adj.deinit();
    var nets = try NetArrays.init(alloc, 8);
    defer nets.deinit();
    nets.is_power[5] = true; // vss
    nets.is_power[6] = true; // vdd

    var result = try extract.extractConstraints(alloc, &devices, &nets, &pins, &adj);
    defer result.deinit();

    // Find the self-symmetric constraint for mn1 (device index 4)
    var found_self_sym = false;
    for (0..result.len) |i| {
        if (result.device_a[i].toInt() == 4 and result.device_b[i].toInt() == 4) {
            found_self_sym = true;
            try std.testing.expectEqual(ConstraintType.symmetry, result.types[i]);
            try std.testing.expect(result.group_id[i] != 0);
            break;
        }
    }
    try std.testing.expect(found_self_sym);
}

test "5T OTA full: mn2-mn3 symmetry, mp4-mp5 load symmetry, mn1 self-sym, all in same group" {
    const alloc = std.testing.allocator;

    var devices = try DeviceArrays.init(alloc, 5);
    defer devices.deinit();
    devices.types[0] = .nmos; // mn2
    devices.types[1] = .nmos; // mn3
    devices.types[2] = .pmos; // mp4
    devices.types[3] = .pmos; // mp5
    devices.types[4] = .nmos; // mn1 tail

    devices.params[0] = .{ .w = 2.0e-6, .l = 0.13e-6, .fingers = 1, .mult = 1, .value = 0.0 };
    devices.params[1] = .{ .w = 2.0e-6, .l = 0.13e-6, .fingers = 1, .mult = 1, .value = 0.0 };
    devices.params[2] = .{ .w = 4.0e-6, .l = 0.13e-6, .fingers = 1, .mult = 1, .value = 0.0 };
    devices.params[3] = .{ .w = 4.0e-6, .l = 0.13e-6, .fingers = 1, .mult = 1, .value = 0.0 };
    devices.params[4] = .{ .w = 4.0e-6, .l = 0.13e-6, .fingers = 1, .mult = 1, .value = 0.0 };

    // Nets: 0=vin, 1=vip, 2=von, 3=vop, 4=tail, 5=vss, 6=vdd, 7=bias
    var pins = try PinEdgeArrays.init(alloc, 20);
    defer pins.deinit();
    setMosfetPins(&pins, 0,  0, 0, 2, 4, 5); // mn2
    setMosfetPins(&pins, 4,  1, 1, 3, 4, 5); // mn3
    setMosfetPins(&pins, 8,  2, 3, 2, 6, 6); // mp4: gate=vop, drain=von, src=vdd
    setMosfetPins(&pins, 12, 3, 3, 3, 6, 6); // mp5: gate=vop, drain=vop, src=vdd (diode)
    setMosfetPins(&pins, 16, 4, 7, 4, 5, 5); // mn1: gate=bias, drain=tail, src=vss

    var adj = try FlatAdjList.buildFromSlices(alloc, 5, 8, 20, pins.device, pins.net);
    defer adj.deinit();
    var nets = try NetArrays.init(alloc, 8);
    defer nets.deinit();
    nets.is_power[5] = true; // vss
    nets.is_power[6] = true; // vdd

    var result = try extract.extractConstraints(alloc, &devices, &nets, &pins, &adj);
    defer result.deinit();

    // Count constraint types
    const sym_count = countConstraintsOfType(&result, .symmetry);
    // Expect: mn2-mn3 seed + mp4-mp5 load + mn1 self-sym = at least 3 symmetry constraints
    try std.testing.expect(sym_count >= 3);

    // No duplicate constraints: each (device_a, device_b) pair should appear only once
    for (0..result.len) |x| {
        for (x + 1..result.len) |y| {
            const same_ab = result.device_a[x].toInt() == result.device_a[y].toInt() and
                result.device_b[x].toInt() == result.device_b[y].toInt();
            const same_ba = result.device_a[x].toInt() == result.device_b[y].toInt() and
                result.device_b[x].toInt() == result.device_a[y].toInt();
            if (same_ab or same_ba) {
                std.debug.print("Duplicate pair at [{d},{d}]: type_x={}, type_y={}\n", .{
                    result.device_a[x].toInt(), result.device_b[x].toInt(),
                    result.types[x],            result.types[y],
                });
            }
            try std.testing.expect(!same_ab and !same_ba);
        }
    }

    // All symmetry constraints must share the same non-zero group_id
    var group: u32 = 0;
    for (0..result.len) |k| {
        if (result.types[k] == .symmetry and result.group_id[k] != 0) {
            if (group == 0) group = result.group_id[k];
            try std.testing.expectEqual(group, result.group_id[k]);
        }
    }
    try std.testing.expect(group != 0);
}

// ─── addConstraintsFromML tests ──────────────────────────────────────────────

test "ML merge: new pair appended with shifted group_id" {
    const alloc = std.testing.allocator;
    var ca = try ConstraintArrays.init(alloc, 0);
    defer ca.deinit();
    // Zig already has one constraint in group 1
    try ca.append(.symmetry, DeviceIdx.fromInt(0), DeviceIdx.fromInt(1), 1.0, std.math.nan(f32), 1);

    // ML adds a new pair (2, 3) in ML group 1 → should become Zig group 2
    const json = "[{\"device_a\":2,\"device_b\":3,\"type\":1,\"weight\":0.85,\"group_id\":1}]";
    try extract.addConstraintsFromML(alloc, &ca, json);

    try std.testing.expectEqual(@as(u32, 2), ca.len);
    try std.testing.expectEqual(ConstraintType.matching, ca.types[1]);
    try std.testing.expectApproxEqAbs(@as(f32, 0.85), ca.weight[1], 1e-6);
    try std.testing.expectEqual(@as(u32, 2), ca.group_id[1]); // shifted: 1 + max(1) = 2
}

test "ML merge: same pair same type → weight = max, no duplicate" {
    const alloc = std.testing.allocator;
    var ca = try ConstraintArrays.init(alloc, 0);
    defer ca.deinit();
    try ca.append(.symmetry, DeviceIdx.fromInt(0), DeviceIdx.fromInt(1), 0.7, std.math.nan(f32), 1);

    const json = "[{\"device_a\":0,\"device_b\":1,\"type\":0,\"weight\":0.95,\"group_id\":1}]";
    try extract.addConstraintsFromML(alloc, &ca, json);

    try std.testing.expectEqual(@as(u32, 1), ca.len); // no duplicate
    try std.testing.expectApproxEqAbs(@as(f32, 0.95), ca.weight[0], 1e-6); // max(0.7, 0.95)
}

test "ML merge: same pair different type → ML type wins" {
    const alloc = std.testing.allocator;
    var ca = try ConstraintArrays.init(alloc, 0);
    defer ca.deinit();
    try ca.append(.proximity, DeviceIdx.fromInt(0), DeviceIdx.fromInt(1), 0.5, std.math.nan(f32), 0);

    // ML says this should be symmetry, not proximity
    const json = "[{\"device_a\":0,\"device_b\":1,\"type\":0,\"weight\":0.92,\"group_id\":2}]";
    try extract.addConstraintsFromML(alloc, &ca, json);

    try std.testing.expectEqual(@as(u32, 1), ca.len);
    try std.testing.expectEqual(ConstraintType.symmetry, ca.types[0]); // ML wins
    try std.testing.expectApproxEqAbs(@as(f32, 0.92), ca.weight[0], 1e-6);
}

test "ML merge: device_a > device_b in JSON → normalised on insert" {
    const alloc = std.testing.allocator;
    var ca = try ConstraintArrays.init(alloc, 0);
    defer ca.deinit();

    // JSON has a=5, b=2 (reversed order)
    const json = "[{\"device_a\":5,\"device_b\":2,\"type\":1,\"weight\":0.8,\"group_id\":1}]";
    try extract.addConstraintsFromML(alloc, &ca, json);

    try std.testing.expectEqual(@as(u32, 1), ca.len);
    // Must be stored normalised: device_a=2, device_b=5
    try std.testing.expectEqual(@as(u32, 2), ca.device_a[0].toInt());
    try std.testing.expectEqual(@as(u32, 5), ca.device_b[0].toInt());
}

test "ML merge: invalid JSON returns error, constraints unchanged" {
    const alloc = std.testing.allocator;
    var ca = try ConstraintArrays.init(alloc, 0);
    defer ca.deinit();
    try ca.append(.symmetry, DeviceIdx.fromInt(0), DeviceIdx.fromInt(1), 1.0, std.math.nan(f32), 1);

    const result = extract.addConstraintsFromML(alloc, &ca, "not valid json");
    try std.testing.expectError(error.SyntaxError, result);
    try std.testing.expectEqual(@as(u32, 1), ca.len); // unchanged
}
