// Exhaustive Liberty generation tests.
//
// These tests exercise the Liberty writer and GDS area parser with various
// cell configurations to ensure correct output for mixed-signal OpenROAD.
//
// Note: Integration tests that require ngspice are in the source module
// tests (src/liberty/lib.zig).  This file covers format correctness.

const std = @import("std");
const testing = std.testing;
const spout = @import("spout");

const liberty = spout.liberty;
const LibertyCell = liberty.LibertyCell;
const LibertyPin = liberty.LibertyPin;
const LibertyConfig = liberty.LibertyConfig;
const TimingArc = liberty.TimingArc;
const InternalPower = liberty.InternalPower;
const BoundingBox = liberty.BoundingBox;
const NldmTable = liberty.types.NldmTable;

// ─── Writer format tests ────────────────────────────────────────────────────

test "Liberty output has correct structure for inverter cell" {
    const alloc = testing.allocator;
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(alloc);

    const cr = try NldmTable.scalar(alloc, 7, 7, 0.0521);
    defer cr.deinit(alloc);
    const cf = try NldmTable.scalar(alloc, 7, 7, 0.0312);
    defer cf.deinit(alloc);
    const rt = try NldmTable.scalar(alloc, 7, 7, 0.0456);
    defer rt.deinit(alloc);
    const ft = try NldmTable.scalar(alloc, 7, 7, 0.0289);
    defer ft.deinit(alloc);
    const rp = try NldmTable.scalar(alloc, 7, 7, 0.00234);
    defer rp.deinit(alloc);
    const fp = try NldmTable.scalar(alloc, 7, 7, 0.00187);
    defer fp.deinit(alloc);

    const timing_arcs = try alloc.alloc(TimingArc, 1);
    defer alloc.free(timing_arcs);
    timing_arcs[0] = .{
        .related_pin = "A",
        .timing_sense = .negative_unate,
        .timing_type = .combinational,
        .cell_rise = cr,
        .cell_fall = cf,
        .rise_transition = rt,
        .fall_transition = ft,
    };

    const int_power = try alloc.alloc(InternalPower, 1);
    defer alloc.free(int_power);
    int_power[0] = .{
        .related_pin = "A",
        .rise_power = rp,
        .fall_power = fp,
    };

    const pins = try alloc.alloc(LibertyPin, 2);
    defer alloc.free(pins);
    pins[0] = .{ .name = "A", .direction = .input, .capacitance = 0.00174, .max_capacitance = 0, .timing_arcs = &.{}, .internal_power = &.{} };
    pins[1] = .{ .name = "Y", .direction = .output, .capacitance = 0, .max_capacitance = 0.2, .timing_arcs = timing_arcs, .internal_power = int_power };

    const cell = LibertyCell{
        .name = "sky130_inv",
        .area = 2.016,
        .leakage_power = 0.123,
        .pg_pins = &.{
            .{ .name = "VPWR", .pg_type = .primary_power, .voltage_name = "VDD" },
            .{ .name = "VGND", .pg_type = .primary_ground, .voltage_name = "VSS" },
        },
        .pins = pins,
    };

    try liberty.writer.writeLiberty(buf.writer(alloc), &cell, LibertyConfig{});
    const out = buf.items;

    // Structural checks
    try testing.expect(std.mem.indexOf(u8, out, "library(spout_analog) {") != null);
    try testing.expect(std.mem.indexOf(u8, out, "cell(sky130_inv) {") != null);
    try testing.expect(std.mem.indexOf(u8, out, "area : 2.016") != null);
    try testing.expect(std.mem.indexOf(u8, out, "timing_sense : negative_unate") != null);
    try testing.expect(std.mem.indexOf(u8, out, "timing_type : combinational") != null);

    // Verify proper nesting (closing braces)
    var depth: i32 = 0;
    for (out) |ch| {
        if (ch == '{') depth += 1;
        if (ch == '}') depth -= 1;
    }
    try testing.expectEqual(@as(i32, 0), depth);
}

test "Liberty output for multi-input analog cell (OTA)" {
    const alloc = testing.allocator;
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(alloc);

    // INP arc tables
    const cr1 = try NldmTable.scalar(alloc, 7, 7, 2.5);
    defer cr1.deinit(alloc);
    const cf1 = try NldmTable.scalar(alloc, 7, 7, 3.1);
    defer cf1.deinit(alloc);
    const rt1 = try NldmTable.scalar(alloc, 7, 7, 1.8);
    defer rt1.deinit(alloc);
    const ft1 = try NldmTable.scalar(alloc, 7, 7, 2.2);
    defer ft1.deinit(alloc);

    // INM arc tables
    const cr2 = try NldmTable.scalar(alloc, 7, 7, 2.6);
    defer cr2.deinit(alloc);
    const cf2 = try NldmTable.scalar(alloc, 7, 7, 3.0);
    defer cf2.deinit(alloc);
    const rt2 = try NldmTable.scalar(alloc, 7, 7, 1.9);
    defer rt2.deinit(alloc);
    const ft2 = try NldmTable.scalar(alloc, 7, 7, 2.1);
    defer ft2.deinit(alloc);

    // Power tables
    const rp1 = try NldmTable.scalar(alloc, 7, 7, 0.5);
    defer rp1.deinit(alloc);
    const fp1 = try NldmTable.scalar(alloc, 7, 7, 0.6);
    defer fp1.deinit(alloc);
    const rp2 = try NldmTable.scalar(alloc, 7, 7, 0.5);
    defer rp2.deinit(alloc);
    const fp2 = try NldmTable.scalar(alloc, 7, 7, 0.6);
    defer fp2.deinit(alloc);

    const timing_arcs = try alloc.alloc(TimingArc, 2);
    defer alloc.free(timing_arcs);
    timing_arcs[0] = .{
        .related_pin = "INP",
        .timing_sense = .positive_unate,
        .timing_type = .combinational,
        .cell_rise = cr1,
        .cell_fall = cf1,
        .rise_transition = rt1,
        .fall_transition = ft1,
    };
    timing_arcs[1] = .{
        .related_pin = "INM",
        .timing_sense = .negative_unate,
        .timing_type = .combinational,
        .cell_rise = cr2,
        .cell_fall = cf2,
        .rise_transition = rt2,
        .fall_transition = ft2,
    };

    const int_power = try alloc.alloc(InternalPower, 2);
    defer alloc.free(int_power);
    int_power[0] = .{ .related_pin = "INP", .rise_power = rp1, .fall_power = fp1 };
    int_power[1] = .{ .related_pin = "INM", .rise_power = rp2, .fall_power = fp2 };

    const pins = try alloc.alloc(LibertyPin, 3);
    defer alloc.free(pins);
    pins[0] = .{ .name = "INP", .direction = .input, .capacitance = 0.0032, .max_capacitance = 0, .timing_arcs = &.{}, .internal_power = &.{} };
    pins[1] = .{ .name = "INM", .direction = .input, .capacitance = 0.0032, .max_capacitance = 0, .timing_arcs = &.{}, .internal_power = &.{} };
    pins[2] = .{ .name = "VOUT", .direction = .output, .capacitance = 0, .max_capacitance = 1.0, .timing_arcs = timing_arcs, .internal_power = int_power };

    const cell = LibertyCell{
        .name = "five_transistor_ota",
        .area = 48.3,
        .leakage_power = 12.5,
        .pg_pins = &.{
            .{ .name = "VDD", .pg_type = .primary_power, .voltage_name = "VDD" },
            .{ .name = "VSS", .pg_type = .primary_ground, .voltage_name = "VSS" },
        },
        .pins = pins,
    };

    try liberty.writer.writeLiberty(buf.writer(alloc), &cell, LibertyConfig{});
    const out = buf.items;

    // Both timing arcs present
    var inp_count: usize = 0;
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, out, pos, "related_pin : \"INP\"")) |idx| {
        inp_count += 1;
        pos = idx + 1;
    }
    try testing.expect(inp_count >= 2);

    // INM arc present
    try testing.expect(std.mem.indexOf(u8, out, "related_pin : \"INM\"") != null);

    // Multiple pins
    try testing.expect(std.mem.indexOf(u8, out, "pin(INP)") != null);
    try testing.expect(std.mem.indexOf(u8, out, "pin(INM)") != null);
    try testing.expect(std.mem.indexOf(u8, out, "pin(VOUT)") != null);
}

// ─── GDS bounding box tests ────────────────────────────────────────────────

test "BoundingBox area calculation" {
    var bbox = BoundingBox.empty();
    try testing.expect(!bbox.valid);
    try testing.expectEqual(@as(f64, 0.0), bbox.areaUm2());

    bbox.extend(0, 0);
    bbox.extend(10000, 5000);
    try testing.expect(bbox.valid);

    const area_db2 = bbox.areaUm2();
    try testing.expectEqual(@as(f64, 50_000_000.0), area_db2);

    // db_unit = 0.001 µm → area = 50e6 * (0.001)^2 = 50 µm²
    const db_unit_um: f64 = 0.001;
    const area_um2 = area_db2 * db_unit_um * db_unit_um;
    try testing.expectApproxEqRel(@as(f64, 50.0), area_um2, 1e-6);
}

test "LibertyConfig custom values" {
    const cfg = LibertyConfig{
        .nom_voltage = 3.3,
        .nom_temperature = 85.0,
        .nom_process = "slow",
        .library_name = "my_analog_lib",
    };

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(testing.allocator);

    const cell = LibertyCell{
        .name = "test",
        .area = 1.0,
        .leakage_power = 0.0,
        .pins = &.{},
        .pg_pins = &.{},
    };

    try liberty.writer.writeLiberty(buf.writer(testing.allocator), &cell, cfg);
    const out = buf.items;

    try testing.expect(std.mem.indexOf(u8, out, "library(my_analog_lib)") != null);
    try testing.expect(std.mem.indexOf(u8, out, "nom_voltage : 3.300") != null);
    try testing.expect(std.mem.indexOf(u8, out, "nom_temperature : 85.0") != null);
}
