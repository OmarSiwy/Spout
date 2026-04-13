// characterize/ext2spice.zig
//
// SPICE netlist writer — converts Spout's internal SoA representation
// (DeviceArrays + PinEdgeArrays + net names) into a flat .spice subcircuit.
//
// This is Spout's equivalent of Magic's ext2spice.c.  Because Spout already
// operates on flattened DeviceArrays there is no hierarchical .ext flattening
// step; we simply walk the arrays and emit one SPICE card per device.
//
// Reference: RTimothyEdwards/magic ext2spice/ext2spice.c  spcdevVisit()
//
// Output format (SPICE3 / ngspice / CDL compatible):
//
//   .subckt <name> <port0> <port1> ...
//   M0 <drain> <gate> <source> <body> <model> W=<w> L=<l> m=<mult>
//   ...
//   .ends <name>
//
// Terminal ordering follows the SPICE convention per device class:
//   MOSFET:   drain gate source body
//   BJT:      collector base emitter [substrate]
//   JFET:     drain gate source
//   Diode:    anode cathode
//   Resistor: node_a node_b
//   Capacitor: node_a node_b
//   Inductor:  node_a node_b
//   Subcircuit: all ports in pin-edge order

const std = @import("std");
const core_types = @import("../core/types.zig");
const device_mod = @import("../core/device_arrays.zig");
const pin_edge_mod = @import("../core/pin_edge_arrays.zig");

const DeviceType = core_types.DeviceType;
const DeviceParams = core_types.DeviceParams;
const DeviceIdx = core_types.DeviceIdx;
const NetIdx = core_types.NetIdx;
const TerminalType = core_types.TerminalType;
const DeviceArrays = device_mod.DeviceArrays;
const PinEdgeArrays = pin_edge_mod.PinEdgeArrays;

// ─── SpiceWriter ────────────────────────────────────────────────────────────

pub const SpiceWriter = struct {

    /// Write a complete .subckt block to `writer`.
    ///
    /// `net_names` maps NetIdx → name string.  The caller must ensure
    /// net_names.len >= every NetIdx referenced in `pins`.
    ///
    /// `ports` lists the NetIdx values that appear in the .subckt port list
    /// (in order).  If null/empty, ports are inferred from power nets +
    /// nets with external connections.
    ///
    /// `subckt_name` is the .subckt identifier.
    pub fn writeSubcircuit(
        writer: anytype,
        subckt_name: []const u8,
        devices: *const DeviceArrays,
        pins: *const PinEdgeArrays,
        net_names: []const []const u8,
        ports: []const NetIdx,
        model_names: ?[]const []const u8,
    ) !void {
        // ── .subckt header ──────────────────────────────────────────
        try writer.print(".subckt {s}", .{subckt_name});
        for (ports) |p| {
            const idx = p.toInt();
            if (idx < net_names.len) {
                try writer.print(" {s}", .{net_names[idx]});
            }
        }
        try writer.writeByte('\n');

        // ── Device cards ────────────────────────────────────────────
        const nd: usize = @intCast(devices.len);
        const np: usize = @intCast(pins.len);

        // Counters per device-class prefix (mirrors Magic's esDevNum, esResNum, etc.)
        var dev_num: u32 = 0;
        var res_num: u32 = 0;
        var cap_num: u32 = 0;
        var ind_num: u32 = 0;
        var diode_num: u32 = 0;
        var bjt_num: u32 = 0;
        var jfet_num: u32 = 0;
        var subckt_num: u32 = 0;

        for (0..nd) |di| {
            const dev_type = devices.types[di];
            const params = devices.params[di];

            // Emit prefix + instance number.
            const prefix = devPrefix(dev_type);
            const num = switch (dev_type) {
                .nmos, .pmos => blk: { const n = dev_num; dev_num += 1; break :blk n; },
                .res, .res_poly, .res_diff_n, .res_diff_p,
                .res_well_n, .res_well_p, .res_metal => blk: { const n = res_num; res_num += 1; break :blk n; },
                .cap, .cap_mim, .cap_mom, .cap_pip, .cap_gate => blk: { const n = cap_num; cap_num += 1; break :blk n; },
                .ind => blk: { const n = ind_num; ind_num += 1; break :blk n; },
                .diode => blk: { const n = diode_num; diode_num += 1; break :blk n; },
                .bjt_npn, .bjt_pnp => blk: { const n = bjt_num; bjt_num += 1; break :blk n; },
                .jfet_n, .jfet_p => blk: { const n = jfet_num; jfet_num += 1; break :blk n; },
                .subckt => blk: { const n = subckt_num; subckt_num += 1; break :blk n; },
            };
            try writer.print("{c}{d}", .{ prefix, num });

            // Emit terminals in SPICE-conventional order.
            try writeTerminals(writer, dev_type, @intCast(di), pins, net_names, np);

            // Emit model name (if provided) or generic type name.
            if (model_names) |mn| {
                if (di < mn.len and mn[di].len > 0) {
                    try writer.print(" {s}", .{mn[di]});
                } else {
                    try writeDefaultModel(writer, dev_type);
                }
            } else {
                try writeDefaultModel(writer, dev_type);
            }

            // Emit parameters.
            try writeParams(writer, dev_type, params);

            try writer.writeByte('\n');
        }

        // ── .ends ───────────────────────────────────────────────────
        try writer.print(".ends {s}\n", .{subckt_name});
    }

    // ── Helpers ─────────────────────────────────────────────────────────────

    /// SPICE device prefix character per device class.
    /// Mirrors Magic ext2spice.c switch on dev->dev_class.
    pub fn devPrefix(dt: DeviceType) u8 {
        return switch (dt) {
            .nmos, .pmos => 'M',
            .res, .res_poly, .res_diff_n, .res_diff_p,
            .res_well_n, .res_well_p, .res_metal => 'R',
            .cap, .cap_mim, .cap_mom, .cap_pip, .cap_gate => 'C',
            .ind => 'L',
            .diode => 'D',
            .bjt_npn, .bjt_pnp => 'Q',
            .jfet_n, .jfet_p => 'J',
            .subckt => 'X',
        };
    }

    const TermNet = struct { terminal: TerminalType, net: NetIdx };

    /// Emit terminal nodes in the conventional order for the device class.
    fn writeTerminals(
        writer: anytype,
        dev_type: DeviceType,
        dev_idx: u32,
        pins: *const PinEdgeArrays,
        net_names: []const []const u8,
        np: usize,
    ) !void {
        // Collect pins belonging to this device.
        // Use a small fixed buffer — devices rarely have > 8 terminals.
        var term_nets: [16]TermNet = undefined;
        var count: usize = 0;
        for (0..np) |pi| {
            if (pins.device[pi].toInt() == dev_idx) {
                if (count < 16) {
                    term_nets[count] = .{ .terminal = pins.terminal[pi], .net = pins.net[pi] };
                    count += 1;
                }
            }
        }

        const order = terminalOrder(dev_type);
        for (order) |wanted| {
            const name = findTermNet(term_nets[0..count], wanted, net_names);
            try writer.print(" {s}", .{name});
        }
    }

    /// Find the net name for a given terminal type in the collected pins.
    fn findTermNet(
        term_nets: []const TermNet,
        wanted: TerminalType,
        net_names: []const []const u8,
    ) []const u8 {
        for (term_nets) |tn| {
            if (tn.terminal == wanted) {
                const idx = tn.net.toInt();
                if (idx < net_names.len) return net_names[idx];
            }
        }
        return "?";
    }

    /// Terminal output order per device class (SPICE convention).
    pub fn terminalOrder(dt: DeviceType) []const TerminalType {
        return switch (dt) {
            // MOSFET: drain gate source body
            .nmos, .pmos => &.{ .drain, .gate, .source, .body },
            // BJT: collector base emitter
            .bjt_npn, .bjt_pnp => &.{ .collector, .base, .emitter },
            // JFET: drain gate source
            .jfet_n, .jfet_p => &.{ .drain, .gate, .source },
            // Diode: anode cathode
            .diode => &.{ .anode, .cathode },
            // Two-terminal passives: anode cathode (or first/second node)
            .res, .res_poly, .res_diff_n, .res_diff_p,
            .res_well_n, .res_well_p, .res_metal,
            .cap, .cap_mim, .cap_mom, .cap_pip, .cap_gate,
            .ind => &.{ .anode, .cathode },
            // Subcircuit: gate source drain body (arbitrary but consistent)
            .subckt => &.{ .gate, .source, .drain, .body },
        };
    }

    /// Emit a default model name when no explicit model is given.
    pub fn writeDefaultModel(writer: anytype, dt: DeviceType) !void {
        const name: []const u8 = switch (dt) {
            .nmos => "nmos",
            .pmos => "pmos",
            .res => "res",
            .res_poly => "res_poly",
            .res_diff_n => "res_diff_n",
            .res_diff_p => "res_diff_p",
            .res_well_n => "res_well_n",
            .res_well_p => "res_well_p",
            .res_metal => "res_metal",
            .cap => "cap",
            .cap_mim => "cap_mim",
            .cap_mom => "cap_mom",
            .cap_pip => "cap_pip",
            .cap_gate => "cap_gate",
            .ind => "ind",
            .diode => "diode",
            .bjt_npn => "npn",
            .bjt_pnp => "pnp",
            .jfet_n => "njf",
            .jfet_p => "pjf",
            .subckt => "subckt",
        };
        try writer.print(" {s}", .{name});
    }

    /// Emit W=, L=, m= parameters as appropriate for the device class.
    pub fn writeParams(writer: anytype, dt: DeviceType, params: DeviceParams) !void {
        switch (dt) {
            .nmos, .pmos => {
                // W and L in scientific notation (SI metres).
                try writer.print(" W={e:.4} L={e:.4}", .{
                    params.w, params.l,
                });
                const mult: u16 = if (params.mult > 0) params.mult else 1;
                if (mult > 1) {
                    try writer.print(" m={d}", .{mult});
                }
                const fingers: u16 = if (params.fingers > 0) params.fingers else 1;
                if (fingers > 1) {
                    try writer.print(" nf={d}", .{fingers});
                }
            },
            .res, .res_poly, .res_diff_n, .res_diff_p,
            .res_well_n, .res_well_p, .res_metal => {
                if (params.value != 0.0) {
                    try writer.print(" {e:.4}", .{params.value});
                }
                if (params.w > 0.0) try writer.print(" W={e:.4}", .{params.w});
                if (params.l > 0.0) try writer.print(" L={e:.4}", .{params.l});
            },
            .cap, .cap_mim, .cap_mom, .cap_pip, .cap_gate => {
                if (params.value != 0.0) {
                    try writer.print(" {e:.4}", .{params.value});
                }
                if (params.w > 0.0) try writer.print(" W={e:.4}", .{params.w});
                if (params.l > 0.0) try writer.print(" L={e:.4}", .{params.l});
            },
            .ind => {
                if (params.value != 0.0) {
                    try writer.print(" {e:.4}", .{params.value});
                }
            },
            .diode, .bjt_npn, .bjt_pnp, .jfet_n, .jfet_p => {
                if (params.w > 0.0) try writer.print(" W={e:.4}", .{params.w});
                if (params.l > 0.0) try writer.print(" L={e:.4}", .{params.l});
            },
            .subckt => {}, // subcircuit params handled externally
        }
    }

    /// Write a standalone SPICE netlist (with header comment and .end).
    pub fn writeNetlist(
        writer: anytype,
        subckt_name: []const u8,
        devices: *const DeviceArrays,
        pins: *const PinEdgeArrays,
        net_names: []const []const u8,
        ports: []const NetIdx,
        model_names: ?[]const []const u8,
    ) !void {
        try writer.print("* SPICE netlist generated by Spout ext2spice\n", .{});
        try writeSubcircuit(writer, subckt_name, devices, pins, net_names, ports, model_names);
        try writer.print(".end\n", .{});
    }

    /// Render to an owned string (caller must free with allocator).
    pub fn renderSubcircuit(
        allocator: std.mem.Allocator,
        subckt_name: []const u8,
        devices: *const DeviceArrays,
        pins: *const PinEdgeArrays,
        net_names: []const []const u8,
        ports: []const NetIdx,
        model_names: ?[]const []const u8,
    ) ![]u8 {
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        errdefer buf.deinit(allocator);
        try writeSubcircuit(buf.writer(allocator), subckt_name, devices, pins, net_names, ports, model_names);
        return buf.toOwnedSlice(allocator);
    }
};

// ─── Tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

fn testBuf() [8192]u8 {
    return undefined;
}

test "ext2spice inverter subcircuit" {
    var da = try DeviceArrays.init(testing.allocator, 2);
    defer da.deinit();
    da.types[0] = .nmos;
    da.params[0] = .{ .w = 1e-6, .l = 0.15e-6, .fingers = 1, .mult = 1, .value = 0 };
    da.types[1] = .pmos;
    da.params[1] = .{ .w = 2e-6, .l = 0.15e-6, .fingers = 1, .mult = 1, .value = 0 };

    var pa = try PinEdgeArrays.init(testing.allocator, 8);
    defer pa.deinit();

    // NMOS: drain=OUT(0), gate=IN(1), source=VSS(2), body=VSS(2)
    pa.device[0] = DeviceIdx.fromInt(0); pa.terminal[0] = .drain;  pa.net[0] = NetIdx.fromInt(0);
    pa.device[1] = DeviceIdx.fromInt(0); pa.terminal[1] = .gate;   pa.net[1] = NetIdx.fromInt(1);
    pa.device[2] = DeviceIdx.fromInt(0); pa.terminal[2] = .source; pa.net[2] = NetIdx.fromInt(2);
    pa.device[3] = DeviceIdx.fromInt(0); pa.terminal[3] = .body;   pa.net[3] = NetIdx.fromInt(2);

    // PMOS: drain=OUT(0), gate=IN(1), source=VDD(3), body=VDD(3)
    pa.device[4] = DeviceIdx.fromInt(1); pa.terminal[4] = .drain;  pa.net[4] = NetIdx.fromInt(0);
    pa.device[5] = DeviceIdx.fromInt(1); pa.terminal[5] = .gate;   pa.net[5] = NetIdx.fromInt(1);
    pa.device[6] = DeviceIdx.fromInt(1); pa.terminal[6] = .source; pa.net[6] = NetIdx.fromInt(3);
    pa.device[7] = DeviceIdx.fromInt(1); pa.terminal[7] = .body;   pa.net[7] = NetIdx.fromInt(3);

    const net_names = [_][]const u8{ "OUT", "IN", "VSS", "VDD" };
    const ports = [_]NetIdx{
        NetIdx.fromInt(3), // VDD
        NetIdx.fromInt(2), // VSS
        NetIdx.fromInt(1), // IN
        NetIdx.fromInt(0), // OUT
    };

    var backing = testBuf();
    var fbs = std.io.fixedBufferStream(&backing);
    try SpiceWriter.writeSubcircuit(
        fbs.writer(), "inverter", &da, &pa, &net_names, &ports, null,
    );
    const output = fbs.getWritten();

    try testing.expect(std.mem.startsWith(u8, output, ".subckt inverter VDD VSS IN OUT\n"));
    try testing.expect(std.mem.indexOf(u8, output, "M0 OUT IN VSS VSS nmos") != null);
    try testing.expect(std.mem.indexOf(u8, output, "M1 OUT IN VDD VDD pmos") != null);
    try testing.expect(std.mem.indexOf(u8, output, ".ends inverter\n") != null);
}

test "ext2spice empty circuit" {
    var da = try DeviceArrays.init(testing.allocator, 0);
    defer da.deinit();
    var pa = try PinEdgeArrays.init(testing.allocator, 0);
    defer pa.deinit();

    var backing = testBuf();
    var fbs = std.io.fixedBufferStream(&backing);
    try SpiceWriter.writeSubcircuit(
        fbs.writer(), "empty", &da, &pa, &.{}, &.{}, null,
    );
    const output = fbs.getWritten();

    try testing.expect(std.mem.startsWith(u8, output, ".subckt empty\n"));
    try testing.expect(std.mem.indexOf(u8, output, ".ends empty\n") != null);
}

test "ext2spice resistor two-terminal" {
    var da = try DeviceArrays.init(testing.allocator, 1);
    defer da.deinit();
    da.types[0] = .res;
    da.params[0] = .{ .w = 0, .l = 0, .fingers = 1, .mult = 1, .value = 10e3 };

    var pa = try PinEdgeArrays.init(testing.allocator, 2);
    defer pa.deinit();
    pa.device[0] = DeviceIdx.fromInt(0); pa.terminal[0] = .anode;   pa.net[0] = NetIdx.fromInt(0);
    pa.device[1] = DeviceIdx.fromInt(0); pa.terminal[1] = .cathode; pa.net[1] = NetIdx.fromInt(1);

    const net_names = [_][]const u8{ "A", "B" };
    const ports = [_]NetIdx{ NetIdx.fromInt(0), NetIdx.fromInt(1) };

    var backing = testBuf();
    var fbs = std.io.fixedBufferStream(&backing);
    try SpiceWriter.writeSubcircuit(
        fbs.writer(), "res_test", &da, &pa, &net_names, &ports, null,
    );

    try testing.expect(std.mem.indexOf(u8, fbs.getWritten(), "R0 A B res") != null);
}

test "ext2spice device prefix characters" {
    try testing.expectEqual(@as(u8, 'M'), SpiceWriter.devPrefix(.nmos));
    try testing.expectEqual(@as(u8, 'M'), SpiceWriter.devPrefix(.pmos));
    try testing.expectEqual(@as(u8, 'R'), SpiceWriter.devPrefix(.res));
    try testing.expectEqual(@as(u8, 'R'), SpiceWriter.devPrefix(.res_poly));
    try testing.expectEqual(@as(u8, 'C'), SpiceWriter.devPrefix(.cap));
    try testing.expectEqual(@as(u8, 'C'), SpiceWriter.devPrefix(.cap_mim));
    try testing.expectEqual(@as(u8, 'L'), SpiceWriter.devPrefix(.ind));
    try testing.expectEqual(@as(u8, 'D'), SpiceWriter.devPrefix(.diode));
    try testing.expectEqual(@as(u8, 'Q'), SpiceWriter.devPrefix(.bjt_npn));
    try testing.expectEqual(@as(u8, 'J'), SpiceWriter.devPrefix(.jfet_n));
    try testing.expectEqual(@as(u8, 'X'), SpiceWriter.devPrefix(.subckt));
}

test "ext2spice MOSFET with multiplier" {
    var da = try DeviceArrays.init(testing.allocator, 1);
    defer da.deinit();
    da.types[0] = .nmos;
    da.params[0] = .{ .w = 4e-6, .l = 0.15e-6, .fingers = 1, .mult = 2, .value = 0 };

    var pa = try PinEdgeArrays.init(testing.allocator, 4);
    defer pa.deinit();
    pa.device[0] = DeviceIdx.fromInt(0); pa.terminal[0] = .drain;  pa.net[0] = NetIdx.fromInt(0);
    pa.device[1] = DeviceIdx.fromInt(0); pa.terminal[1] = .gate;   pa.net[1] = NetIdx.fromInt(1);
    pa.device[2] = DeviceIdx.fromInt(0); pa.terminal[2] = .source; pa.net[2] = NetIdx.fromInt(2);
    pa.device[3] = DeviceIdx.fromInt(0); pa.terminal[3] = .body;   pa.net[3] = NetIdx.fromInt(2);

    const net_names = [_][]const u8{ "D", "G", "S" };

    var backing = testBuf();
    var fbs = std.io.fixedBufferStream(&backing);
    try SpiceWriter.writeSubcircuit(
        fbs.writer(), "mult_test", &da, &pa, &net_names, &.{}, null,
    );

    try testing.expect(std.mem.indexOf(u8, fbs.getWritten(), "m=2") != null);
}

test "ext2spice MOSFET with fingers" {
    var da = try DeviceArrays.init(testing.allocator, 1);
    defer da.deinit();
    da.types[0] = .pmos;
    da.params[0] = .{ .w = 2e-6, .l = 0.15e-6, .fingers = 4, .mult = 1, .value = 0 };

    var pa = try PinEdgeArrays.init(testing.allocator, 4);
    defer pa.deinit();
    pa.device[0] = DeviceIdx.fromInt(0); pa.terminal[0] = .drain;  pa.net[0] = NetIdx.fromInt(0);
    pa.device[1] = DeviceIdx.fromInt(0); pa.terminal[1] = .gate;   pa.net[1] = NetIdx.fromInt(1);
    pa.device[2] = DeviceIdx.fromInt(0); pa.terminal[2] = .source; pa.net[2] = NetIdx.fromInt(2);
    pa.device[3] = DeviceIdx.fromInt(0); pa.terminal[3] = .body;   pa.net[3] = NetIdx.fromInt(3);

    const net_names = [_][]const u8{ "D", "G", "S", "B" };

    var backing = testBuf();
    var fbs = std.io.fixedBufferStream(&backing);
    try SpiceWriter.writeSubcircuit(
        fbs.writer(), "nf_test", &da, &pa, &net_names, &.{}, null,
    );

    try testing.expect(std.mem.indexOf(u8, fbs.getWritten(), "nf=4") != null);
}

test "ext2spice with explicit model names" {
    var da = try DeviceArrays.init(testing.allocator, 2);
    defer da.deinit();
    da.types[0] = .nmos;
    da.params[0] = .{ .w = 2e-6, .l = 0.15e-6, .fingers = 1, .mult = 1, .value = 0 };
    da.types[1] = .pmos;
    da.params[1] = .{ .w = 4e-6, .l = 0.15e-6, .fingers = 1, .mult = 1, .value = 0 };

    var pa = try PinEdgeArrays.init(testing.allocator, 8);
    defer pa.deinit();
    pa.device[0] = DeviceIdx.fromInt(0); pa.terminal[0] = .drain;  pa.net[0] = NetIdx.fromInt(0);
    pa.device[1] = DeviceIdx.fromInt(0); pa.terminal[1] = .gate;   pa.net[1] = NetIdx.fromInt(1);
    pa.device[2] = DeviceIdx.fromInt(0); pa.terminal[2] = .source; pa.net[2] = NetIdx.fromInt(2);
    pa.device[3] = DeviceIdx.fromInt(0); pa.terminal[3] = .body;   pa.net[3] = NetIdx.fromInt(2);
    pa.device[4] = DeviceIdx.fromInt(1); pa.terminal[4] = .drain;  pa.net[4] = NetIdx.fromInt(0);
    pa.device[5] = DeviceIdx.fromInt(1); pa.terminal[5] = .gate;   pa.net[5] = NetIdx.fromInt(1);
    pa.device[6] = DeviceIdx.fromInt(1); pa.terminal[6] = .source; pa.net[6] = NetIdx.fromInt(3);
    pa.device[7] = DeviceIdx.fromInt(1); pa.terminal[7] = .body;   pa.net[7] = NetIdx.fromInt(3);

    const net_names = [_][]const u8{ "OUT", "IN", "VSS", "VDD" };
    const models = [_][]const u8{ "sky130_fd_pr__nfet_01v8", "sky130_fd_pr__pfet_01v8" };

    var backing = testBuf();
    var fbs = std.io.fixedBufferStream(&backing);
    try SpiceWriter.writeSubcircuit(
        fbs.writer(), "inv_sky130", &da, &pa, &net_names, &.{}, &models,
    );
    const output = fbs.getWritten();

    try testing.expect(std.mem.indexOf(u8, output, "sky130_fd_pr__nfet_01v8") != null);
    try testing.expect(std.mem.indexOf(u8, output, "sky130_fd_pr__pfet_01v8") != null);
}

test "ext2spice five transistor OTA matches reference structure" {
    var da = try DeviceArrays.init(testing.allocator, 5);
    defer da.deinit();
    for (0..2) |i| {
        da.types[i] = .nmos;
        da.params[i] = .{ .w = 2e-6, .l = 0.15e-6, .fingers = 1, .mult = 1, .value = 0 };
    }
    for (2..4) |i| {
        da.types[i] = .pmos;
        da.params[i] = .{ .w = 4e-6, .l = 0.15e-6, .fingers = 1, .mult = 1, .value = 0 };
    }
    da.types[4] = .nmos;
    da.params[4] = .{ .w = 4e-6, .l = 0.15e-6, .fingers = 1, .mult = 2, .value = 0 };

    const net_names = [_][]const u8{ "VDD", "VSS", "INP", "INN", "OUT", "tail", "diff_a", "diff_b", "bias_n" };

    var pa = try PinEdgeArrays.init(testing.allocator, 20);
    defer pa.deinit();

    // M0: drain=tail(5), gate=INP(2), source=diff_a(6), body=VSS(1)
    inline for (.{ .{ 0, .drain, 5 }, .{ 0, .gate, 2 }, .{ 0, .source, 6 }, .{ 0, .body, 1 } }, 0..) |t, i| {
        pa.device[i] = DeviceIdx.fromInt(t[0]); pa.terminal[i] = t[1]; pa.net[i] = NetIdx.fromInt(t[2]);
    }
    // M1: drain=tail(5), gate=INN(3), source=diff_b(7), body=VSS(1)
    inline for (.{ .{ 1, .drain, 5 }, .{ 1, .gate, 3 }, .{ 1, .source, 7 }, .{ 1, .body, 1 } }, 0..) |t, i| {
        pa.device[4 + i] = DeviceIdx.fromInt(t[0]); pa.terminal[4 + i] = t[1]; pa.net[4 + i] = NetIdx.fromInt(t[2]);
    }
    // M2: drain=VDD(0), gate=VDD(0), source=diff_a(6), body=VDD(0)
    inline for (.{ .{ 2, .drain, 0 }, .{ 2, .gate, 0 }, .{ 2, .source, 6 }, .{ 2, .body, 0 } }, 0..) |t, i| {
        pa.device[8 + i] = DeviceIdx.fromInt(t[0]); pa.terminal[8 + i] = t[1]; pa.net[8 + i] = NetIdx.fromInt(t[2]);
    }
    // M3: drain=VDD(0), gate=VDD(0), source=diff_b(7), body=VDD(0)
    inline for (.{ .{ 3, .drain, 0 }, .{ 3, .gate, 0 }, .{ 3, .source, 7 }, .{ 3, .body, 0 } }, 0..) |t, i| {
        pa.device[12 + i] = DeviceIdx.fromInt(t[0]); pa.terminal[12 + i] = t[1]; pa.net[12 + i] = NetIdx.fromInt(t[2]);
    }
    // M4: drain=tail(5), gate=bias_n(8), source=VSS(1), body=VSS(1)
    inline for (.{ .{ 4, .drain, 5 }, .{ 4, .gate, 8 }, .{ 4, .source, 1 }, .{ 4, .body, 1 } }, 0..) |t, i| {
        pa.device[16 + i] = DeviceIdx.fromInt(t[0]); pa.terminal[16 + i] = t[1]; pa.net[16 + i] = NetIdx.fromInt(t[2]);
    }

    const ports = [_]NetIdx{
        NetIdx.fromInt(0), NetIdx.fromInt(1), NetIdx.fromInt(2),
        NetIdx.fromInt(3), NetIdx.fromInt(4),
    };

    var backing = testBuf();
    var fbs = std.io.fixedBufferStream(&backing);
    try SpiceWriter.writeSubcircuit(
        fbs.writer(), "five_transistor_ota", &da, &pa, &net_names, &ports, null,
    );
    const output = fbs.getWritten();

    try testing.expect(std.mem.startsWith(u8, output, ".subckt five_transistor_ota VDD VSS INP INN OUT\n"));
    try testing.expect(std.mem.indexOf(u8, output, "M0 tail INP diff_a VSS nmos") != null);
    try testing.expect(std.mem.indexOf(u8, output, "M1 tail INN diff_b VSS nmos") != null);
    try testing.expect(std.mem.indexOf(u8, output, "M2 VDD VDD diff_a VDD pmos") != null);
    try testing.expect(std.mem.indexOf(u8, output, "M3 VDD VDD diff_b VDD pmos") != null);
    try testing.expect(std.mem.indexOf(u8, output, "M4 tail bias_n VSS VSS nmos") != null);
    try testing.expect(std.mem.indexOf(u8, output, ".ends five_transistor_ota\n") != null);
}

test "ext2spice renderSubcircuit returns owned string" {
    var da = try DeviceArrays.init(testing.allocator, 0);
    defer da.deinit();
    var pa = try PinEdgeArrays.init(testing.allocator, 0);
    defer pa.deinit();

    const result = try SpiceWriter.renderSubcircuit(
        testing.allocator, "test", &da, &pa, &.{}, &.{}, null,
    );
    defer testing.allocator.free(result);

    try testing.expect(std.mem.indexOf(u8, result, ".subckt test") != null);
    try testing.expect(std.mem.indexOf(u8, result, ".ends test") != null);
}

test "ext2spice BJT device" {
    var da = try DeviceArrays.init(testing.allocator, 1);
    defer da.deinit();
    da.types[0] = .bjt_npn;
    da.params[0] = .{ .w = 0, .l = 0, .fingers = 1, .mult = 1, .value = 0 };

    var pa = try PinEdgeArrays.init(testing.allocator, 3);
    defer pa.deinit();
    pa.device[0] = DeviceIdx.fromInt(0); pa.terminal[0] = .collector; pa.net[0] = NetIdx.fromInt(0);
    pa.device[1] = DeviceIdx.fromInt(0); pa.terminal[1] = .base;     pa.net[1] = NetIdx.fromInt(1);
    pa.device[2] = DeviceIdx.fromInt(0); pa.terminal[2] = .emitter;  pa.net[2] = NetIdx.fromInt(2);

    const net_names = [_][]const u8{ "C", "B", "E" };

    var backing = testBuf();
    var fbs = std.io.fixedBufferStream(&backing);
    try SpiceWriter.writeSubcircuit(
        fbs.writer(), "bjt_test", &da, &pa, &net_names, &.{}, null,
    );

    try testing.expect(std.mem.indexOf(u8, fbs.getWritten(), "Q0 C B E npn") != null);
}

test "ext2spice mixed device types" {
    var da = try DeviceArrays.init(testing.allocator, 3);
    defer da.deinit();
    da.types[0] = .nmos;
    da.params[0] = .{ .w = 1e-6, .l = 0.15e-6, .fingers = 1, .mult = 1, .value = 0 };
    da.types[1] = .res;
    da.params[1] = .{ .w = 0, .l = 0, .fingers = 1, .mult = 1, .value = 1e3 };
    da.types[2] = .cap;
    da.params[2] = .{ .w = 0, .l = 0, .fingers = 1, .mult = 1, .value = 1e-12 };

    var pa = try PinEdgeArrays.init(testing.allocator, 8);
    defer pa.deinit();
    pa.device[0] = DeviceIdx.fromInt(0); pa.terminal[0] = .drain;  pa.net[0] = NetIdx.fromInt(0);
    pa.device[1] = DeviceIdx.fromInt(0); pa.terminal[1] = .gate;   pa.net[1] = NetIdx.fromInt(1);
    pa.device[2] = DeviceIdx.fromInt(0); pa.terminal[2] = .source; pa.net[2] = NetIdx.fromInt(2);
    pa.device[3] = DeviceIdx.fromInt(0); pa.terminal[3] = .body;   pa.net[3] = NetIdx.fromInt(2);
    pa.device[4] = DeviceIdx.fromInt(1); pa.terminal[4] = .anode;   pa.net[4] = NetIdx.fromInt(0);
    pa.device[5] = DeviceIdx.fromInt(1); pa.terminal[5] = .cathode; pa.net[5] = NetIdx.fromInt(3);
    pa.device[6] = DeviceIdx.fromInt(2); pa.terminal[6] = .anode;   pa.net[6] = NetIdx.fromInt(3);
    pa.device[7] = DeviceIdx.fromInt(2); pa.terminal[7] = .cathode; pa.net[7] = NetIdx.fromInt(2);

    const net_names = [_][]const u8{ "D", "G", "VSS", "N1" };

    var backing = testBuf();
    var fbs = std.io.fixedBufferStream(&backing);
    try SpiceWriter.writeSubcircuit(
        fbs.writer(), "mixed", &da, &pa, &net_names, &.{}, null,
    );
    const output = fbs.getWritten();

    try testing.expect(std.mem.indexOf(u8, output, "M0 D G VSS VSS nmos") != null);
    try testing.expect(std.mem.indexOf(u8, output, "R0 D N1 res") != null);
    try testing.expect(std.mem.indexOf(u8, output, "C0 N1 VSS cap") != null);
}
