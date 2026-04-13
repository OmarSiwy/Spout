// liberty/writer.zig
//
// Liberty (.lib) format writer.
//
// Emits a valid Liberty file from a LibertyCell data model.  The output
// targets OpenROAD's read_liberty parser and follows the Synopsys Liberty
// Reference Manual syntax.
//
// Structure:
//   library(<name>) {
//     technology(cmos);
//     operating_conditions(...) { ... }
//     cell(<name>) {
//       area : <value>;
//       cell_leakage_power : <value>;
//       pin(<name>) {
//         direction : input|output;
//         capacitance : <value>;
//         timing() { ... }
//         internal_power() { ... }
//       }
//     }
//   }

const std = @import("std");
const types = @import("types.zig");

const LibertyCell = types.LibertyCell;
const LibertyConfig = types.LibertyConfig;
const LibertyPin = types.LibertyPin;
const TimingArc = types.TimingArc;
const InternalPower = types.InternalPower;
const PgPin = types.PgPin;
const NldmTable = types.NldmTable;
const NLDM_SIZE = types.NLDM_SIZE;

// ─── Main writer ────────────────────────────────────────────────────────────

pub fn writeLiberty(out: anytype, cell: *const LibertyCell, config: LibertyConfig) !void {
    // Library header
    try out.print("library({s}) {{\n", .{config.library_name});
    try out.print("  technology (cmos);\n", .{});
    try out.print("  delay_model : table_lookup;\n", .{});
    try out.print("  time_unit : \"{s}\";\n", .{config.time_unit});
    try out.print("  voltage_unit : \"{s}\";\n", .{config.voltage_unit});
    try out.print("  current_unit : \"{s}\";\n", .{config.current_unit});
    try out.print("  pulling_resistance_unit : \"1kohm\";\n", .{});
    try out.print("  capacitive_load_unit(1, pf);\n", .{});
    try out.print("  leakage_power_unit : \"{s}\";\n", .{config.leaking_power_unit});
    try out.print("  nom_process : 1;\n", .{});
    try out.print("  nom_voltage : {d:.3};\n", .{config.nom_voltage});
    try out.print("  nom_temperature : {d:.1};\n", .{config.nom_temperature});
    try out.writeAll("\n");

    // Voltage map
    try out.print("  voltage_map(VDD, {d:.2});\n", .{config.nom_voltage});
    try out.writeAll("  voltage_map(VSS, 0.00);\n\n");

    // NLDM table templates
    try writeTableTemplate(out, "delay_template_7x7", &config.slew_indices, &config.load_indices);
    try writeTableTemplate(out, "power_template_7x7", &config.slew_indices, &config.load_indices);

    // Operating conditions
    try out.print("  operating_conditions(\"{s}\") {{\n", .{config.nom_process});
    try out.print("    process : 1;\n", .{});
    try out.print("    voltage : {d:.3};\n", .{config.nom_voltage});
    try out.print("    temperature : {d:.1};\n", .{config.nom_temperature});
    try out.print("  }}\n", .{});
    try out.print("  default_operating_conditions : \"{s}\";\n\n", .{config.nom_process});

    // Cell
    try out.print("  cell({s}) {{\n", .{cell.name});
    try out.print("    area : {d:.6};\n", .{cell.area});
    try out.print("    cell_leakage_power : {d:.6};\n", .{cell.leakage_power});
    try out.writeAll("\n");

    // pg_pin groups (power/ground)
    for (cell.pg_pins) |pg| {
        try writePgPin(out, &pg);
    }

    // Signal pins
    for (cell.pins) |pin| {
        try writePin(out, &pin);
    }

    try out.writeAll("  }\n"); // end cell
    try out.writeAll("}\n"); // end library
}

fn writeTableTemplate(out: anytype, name: []const u8, index_1: []const f64, index_2: []const f64) !void {
    try out.print("  lu_table_template({s}) {{\n", .{name});
    try out.writeAll("    variable_1 : input_net_transition;\n");
    try out.writeAll("    variable_2 : total_output_net_capacitance;\n");
    try writeIndexLine(out, "    index_1", index_1);
    try writeIndexLine(out, "    index_2", index_2);
    try out.writeAll("  }\n\n");
}

fn writeIndexLine(out: anytype, prefix: []const u8, values: []const f64) !void {
    try out.print("{s} (\"", .{prefix});
    for (values, 0..) |v, i| {
        if (i > 0) try out.writeAll(", ");
        try out.print("{d:.4}", .{v});
    }
    try out.writeAll("\");\n");
}

fn writePgPin(out: anytype, pg: *const PgPin) !void {
    try out.print("    pg_pin({s}) {{\n", .{pg.name});
    try out.print("      pg_type : {s};\n", .{pg.pg_type.asString()});
    try out.print("      voltage_name : {s};\n", .{pg.voltage_name});
    try out.writeAll("    }\n");
}

fn writePin(out: anytype, pin: *const LibertyPin) !void {
    try out.print("    pin({s}) {{\n", .{pin.name});
    try out.print("      direction : {s};\n", .{pin.direction.asString()});

    if (pin.capacitance > 0.0) {
        try out.print("      capacitance : {d:.6};\n", .{pin.capacitance});
    }
    if (pin.max_capacitance > 0.0) {
        try out.print("      max_capacitance : {d:.6};\n", .{pin.max_capacitance});
    }

    // Timing arcs
    for (pin.timing_arcs) |arc| {
        try writeTimingArc(out, &arc);
    }

    // Internal power
    for (pin.internal_power) |pwr| {
        try writeInternalPower(out, &pwr);
    }

    try out.writeAll("    }\n"); // end pin
}

fn writeTimingArc(out: anytype, arc: *const TimingArc) !void {
    try out.writeAll("      timing() {\n");
    try out.print("        related_pin : \"{s}\";\n", .{arc.related_pin});
    if (arc.related_power_pin) |pp| {
        try out.print("        related_power_pin : \"{s}\";\n", .{pp});
    }
    if (arc.related_ground_pin) |gp| {
        try out.print("        related_ground_pin : \"{s}\";\n", .{gp});
    }
    try out.print("        timing_sense : {s};\n", .{arc.timing_sense.asString()});
    try out.print("        timing_type : {s};\n", .{arc.timing_type.asString()});

    try writeNldmBlock(out, "cell_rise", "delay_template_7x7", &arc.cell_rise);
    try writeNldmBlock(out, "cell_fall", "delay_template_7x7", &arc.cell_fall);
    try writeNldmBlock(out, "rise_transition", "delay_template_7x7", &arc.rise_transition);
    try writeNldmBlock(out, "fall_transition", "delay_template_7x7", &arc.fall_transition);

    try out.writeAll("      }\n"); // end timing
}

fn writeInternalPower(out: anytype, pwr: *const InternalPower) !void {
    try out.writeAll("      internal_power() {\n");
    try out.print("        related_pin : \"{s}\";\n", .{pwr.related_pin});
    if (pwr.related_pg_pin) |pg| {
        try out.print("        related_pg_pin : \"{s}\";\n", .{pg});
    }

    try writeNldmBlock(out, "rise_power", "power_template_7x7", &pwr.rise_power);
    try writeNldmBlock(out, "fall_power", "power_template_7x7", &pwr.fall_power);

    try out.writeAll("      }\n"); // end internal_power
}

fn writeNldmBlock(out: anytype, name: []const u8, template: []const u8, table: *const NldmTable) !void {
    try out.print("        {s}({s}) {{\n", .{ name, template });
    try out.writeAll("          values (\n");
    for (0..NLDM_SIZE) |i| {
        try out.writeAll("            \"");
        for (0..NLDM_SIZE) |j| {
            if (j > 0) try out.writeAll(", ");
            try out.print("{d:.6}", .{table.values[i][j]});
        }
        if (i < NLDM_SIZE - 1) {
            try out.writeAll("\",\n");
        } else {
            try out.writeAll("\"\n");
        }
    }
    try out.writeAll("          );\n");
    try out.writeAll("        }\n");
}

// ─── Tests ──────────────────────────────────────────────────────────────────

test "writeLiberty minimal cell" {
    const PgPinType = types.PgPinType;
    var buf = std.ArrayList(u8).init(std.testing.allocator);
    defer buf.deinit();

    const cell = LibertyCell{
        .name = "test_inv",
        .area = 1.234,
        .leakage_power = 0.567,
        .pg_pins = &.{
            .{ .name = "VPWR", .pg_type = PgPinType.primary_power, .voltage_name = "VDD" },
            .{ .name = "VGND", .pg_type = PgPinType.primary_ground, .voltage_name = "VSS" },
        },
        .pins = &.{
            LibertyPin{
                .name = "A",
                .direction = .input,
                .capacitance = 0.002,
                .max_capacitance = 0.0,
                .timing_arcs = &.{},
                .internal_power = &.{},
            },
            LibertyPin{
                .name = "Y",
                .direction = .output,
                .capacitance = 0.0,
                .max_capacitance = 0.1,
                .timing_arcs = &.{
                    TimingArc{
                        .related_pin = "A",
                        .timing_sense = .negative_unate,
                        .timing_type = .combinational,
                        .cell_rise = NldmTable.scalar(0.05),
                        .cell_fall = NldmTable.scalar(0.04),
                        .rise_transition = NldmTable.scalar(0.03),
                        .fall_transition = NldmTable.scalar(0.02),
                    },
                },
                .internal_power = &.{
                    InternalPower{
                        .related_pin = "A",
                        .rise_power = NldmTable.scalar(0.001),
                        .fall_power = NldmTable.scalar(0.002),
                    },
                },
            },
        },
    };

    const config = LibertyConfig{};
    try writeLiberty(buf.writer(), &cell, config);

    const output = buf.items;

    // Library structure
    try std.testing.expect(std.mem.indexOf(u8, output, "library(spout_analog)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "technology (cmos)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "nom_voltage : 1.800") != null);

    // Voltage map
    try std.testing.expect(std.mem.indexOf(u8, output, "voltage_map(VDD, 1.80)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "voltage_map(VSS, 0.00)") != null);

    // NLDM table template
    try std.testing.expect(std.mem.indexOf(u8, output, "lu_table_template(delay_template_7x7)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "input_net_transition") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "total_output_net_capacitance") != null);

    // pg_pin groups
    try std.testing.expect(std.mem.indexOf(u8, output, "pg_pin(VPWR)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "pg_type : primary_power") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "voltage_name : VDD") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "pg_pin(VGND)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "pg_type : primary_ground") != null);

    // Cell and pins
    try std.testing.expect(std.mem.indexOf(u8, output, "cell(test_inv)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "area : 1.234") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "pin(A)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "pin(Y)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "related_pin : \"A\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "timing_sense : negative_unate") != null);

    // NLDM 2D tables (not scalar)
    try std.testing.expect(std.mem.indexOf(u8, output, "cell_rise(delay_template_7x7)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "rise_power(power_template_7x7)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "values (") != null);
}

test "writeLiberty pg_pin only cell" {
    const PgPinType = types.PgPinType;
    var buf = std.ArrayList(u8).init(std.testing.allocator);
    defer buf.deinit();

    const cell = LibertyCell{
        .name = "pwr_cell",
        .area = 0.0,
        .leakage_power = 0.0,
        .pg_pins = &.{
            .{ .name = "VDD", .pg_type = PgPinType.primary_power, .voltage_name = "VDD" },
            .{ .name = "VSS", .pg_type = PgPinType.primary_ground, .voltage_name = "VSS" },
        },
        .pins = &.{},
    };

    try writeLiberty(buf.writer(), &cell, LibertyConfig{});
    const output = buf.items;

    // pg_pin groups present
    try std.testing.expect(std.mem.indexOf(u8, output, "pg_pin(VDD)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "pg_type : primary_power") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "pg_pin(VSS)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "pg_type : primary_ground") != null);
    // No signal pins or timing arcs
    try std.testing.expect(std.mem.indexOf(u8, output, "timing()") == null);
}
