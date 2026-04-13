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
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(testing.allocator);

    const cell = LibertyCell{
        .name = "sky130_inv",
        .area = 2.016,
        .leakage_power = 0.123,
        .pg_pins = &.{
            .{ .name = "VPWR", .pg_type = .primary_power, .voltage_name = "VDD" },
            .{ .name = "VGND", .pg_type = .primary_ground, .voltage_name = "VSS" },
        },
        .pins = &.{
            LibertyPin{
                .name = "A",
                .direction = .input,
                .capacitance = 0.00174,
                .max_capacitance = 0,
                .timing_arcs = &.{},
                .internal_power = &.{},
            },
            LibertyPin{
                .name = "Y",
                .direction = .output,
                .capacitance = 0,
                .max_capacitance = 0.2,
                .timing_arcs = &.{
                    TimingArc{
                        .related_pin = "A",
                        .timing_sense = .negative_unate,
                        .timing_type = .combinational,
                        .cell_rise = NldmTable.scalar(0.0521),
                        .cell_fall = NldmTable.scalar(0.0312),
                        .rise_transition = NldmTable.scalar(0.0456),
                        .fall_transition = NldmTable.scalar(0.0289),
                    },
                },
                .internal_power = &.{
                    InternalPower{
                        .related_pin = "A",
                        .rise_power = NldmTable.scalar(0.00234),
                        .fall_power = NldmTable.scalar(0.00187),
                    },
                },
            },
        },
    };

    try liberty.writer.writeLiberty(buf.writer(testing.allocator), &cell, LibertyConfig{});
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
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(testing.allocator);

    const cell = LibertyCell{
        .name = "five_transistor_ota",
        .area = 48.3,
        .leakage_power = 12.5,
        .pg_pins = &.{
            .{ .name = "VDD", .pg_type = .primary_power, .voltage_name = "VDD" },
            .{ .name = "VSS", .pg_type = .primary_ground, .voltage_name = "VSS" },
        },
        .pins = &.{
            LibertyPin{
                .name = "INP",
                .direction = .input,
                .capacitance = 0.0032,
                .max_capacitance = 0,
                .timing_arcs = &.{},
                .internal_power = &.{},
            },
            LibertyPin{
                .name = "INM",
                .direction = .input,
                .capacitance = 0.0032,
                .max_capacitance = 0,
                .timing_arcs = &.{},
                .internal_power = &.{},
            },
            LibertyPin{
                .name = "VOUT",
                .direction = .output,
                .capacitance = 0,
                .max_capacitance = 1.0,
                .timing_arcs = &.{
                    TimingArc{
                        .related_pin = "INP",
                        .timing_sense = .positive_unate,
                        .timing_type = .combinational,
                        .cell_rise = NldmTable.scalar(2.5),
                        .cell_fall = NldmTable.scalar(3.1),
                        .rise_transition = NldmTable.scalar(1.8),
                        .fall_transition = NldmTable.scalar(2.2),
                    },
                    TimingArc{
                        .related_pin = "INM",
                        .timing_sense = .negative_unate,
                        .timing_type = .combinational,
                        .cell_rise = NldmTable.scalar(2.6),
                        .cell_fall = NldmTable.scalar(3.0),
                        .rise_transition = NldmTable.scalar(1.9),
                        .fall_transition = NldmTable.scalar(2.1),
                    },
                },
                .internal_power = &.{
                    InternalPower{ .related_pin = "INP", .rise_power = NldmTable.scalar(0.5), .fall_power = NldmTable.scalar(0.6) },
                    InternalPower{ .related_pin = "INM", .rise_power = NldmTable.scalar(0.5), .fall_power = NldmTable.scalar(0.6) },
                },
            },
        },
    };

    try liberty.writer.writeLiberty(buf.writer(testing.allocator), &cell, LibertyConfig{});
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
