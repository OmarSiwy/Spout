// liberty/lib.zig
//
// Public API for Liberty (.lib) file generation from GDS + SPICE.
//
// Generates Liberty timing/power/area models for analog cells, targeting
// mixed-signal OpenROAD flows.  Characterization uses ngspice simulation
// for accurate analog timing and power data.
//
// Usage:
//   const liberty = @import("liberty/lib.zig");
//   var buf = std.ArrayList(u8).init(allocator);
//   try liberty.generateLiberty(buf.writer(), gds_path, spice_path, "my_cell", .{}, allocator);

const std = @import("std");

pub const types = @import("types.zig");
pub const gds_area = @import("gds_area.zig");
pub const spice_sim = @import("spice_sim.zig");
pub const writer = @import("writer.zig");

// ─── Type re-exports ────────────────────────────────────────────────────────

pub const LibertyConfig = types.LibertyConfig;
pub const LibertyCell = types.LibertyCell;
pub const LibertyPin = types.LibertyPin;
pub const TimingArc = types.TimingArc;
pub const InternalPower = types.InternalPower;
pub const PinDirection = types.PinDirection;
pub const TimingSense = types.TimingSense;
pub const TimingType = types.TimingType;
pub const BoundingBox = gds_area.BoundingBox;

// ─── Main entry point ───────────────────────────────────────────────────────

/// Generate a Liberty (.lib) file for an analog cell.
///
/// Inputs:
///   - out:        Writer for Liberty output
///   - gds_path:   Path to GDSII binary file (for area extraction)
///   - spice_path: Path to SPICE netlist (.spice/.sp) with .subckt definition
///   - cell_name:  Name of the cell (used in Liberty cell() group)
///   - config:     Characterization parameters (voltage, temp, model paths, etc.)
///   - allocator:  Memory allocator for temporary buffers
///
/// The function:
///   1. Parses GDS to compute cell bounding-box area
///   2. Parses SPICE netlist to identify subcircuit ports and their directions
///   3. Runs ngspice DC analysis for leakage power
///   4. Runs ngspice transient analysis per input→output arc for timing
///   5. Writes complete Liberty file to `out`
pub fn generateLiberty(
    out: anytype,
    gds_path: []const u8,
    spice_path: []const u8,
    cell_name: []const u8,
    config: LibertyConfig,
    allocator: std.mem.Allocator,
) !void {
    // 1. Area from GDS bounding box (convert db-units² to µm²)
    const bbox = try gds_area.readBoundingBox(gds_path, config.gds_db_unit_um);
    const area_um2 = bbox.areaUm2() * config.gds_db_unit_um * config.gds_db_unit_um;

    // 2. Parse SPICE netlist for port info
    var sim_ctx = try spice_sim.SimContext.init(
        allocator,
        spice_path,
        cell_name,
        config,
    );
    defer sim_ctx.deinit();

    // 3. Run DC operating point for leakage power
    const leakage_nw = try sim_ctx.measureLeakagePower();

    // 4. Run transient sims (NxM NLDM sweep) for each timing arc
    const char_result = try sim_ctx.characterizePins(allocator);
    defer {
        for (char_result.pins) |p| {
            for (p.timing_arcs) |arc| {
                arc.cell_rise.deinit(allocator);
                arc.cell_fall.deinit(allocator);
                arc.rise_transition.deinit(allocator);
                arc.fall_transition.deinit(allocator);
            }
            for (p.internal_power) |pwr| {
                pwr.rise_power.deinit(allocator);
                pwr.fall_power.deinit(allocator);
            }
            allocator.free(p.timing_arcs);
            allocator.free(p.internal_power);
        }
        allocator.free(char_result.pins);
        allocator.free(char_result.pg_pins);
    }

    // 5. Build cell model and write Liberty
    const cell = LibertyCell{
        .name = cell_name,
        .area = area_um2,
        .leakage_power = leakage_nw,
        .pins = char_result.pins,
        .pg_pins = char_result.pg_pins,
    };

    try writer.writeLiberty(out, &cell, config);
}

// ─── Multi-corner characterization ──────────────────────────────────────────

pub const CornerSpec = struct {
    name: []const u8,
    model_corner: []const u8,
    nom_voltage: f64,
    nom_temperature: f64,
};

/// Pre-defined sky130 corners.
pub const sky130_corners = [_]CornerSpec{
    .{ .name = "tt_025C_1v80", .model_corner = "tt", .nom_voltage = 1.80, .nom_temperature = 25.0 },
    .{ .name = "ss_100C_1v60", .model_corner = "ss", .nom_voltage = 1.60, .nom_temperature = 100.0 },
    .{ .name = "ff_n40C_1v95", .model_corner = "ff", .nom_voltage = 1.95, .nom_temperature = -40.0 },
};

/// Apply a corner spec to a base config, returning a modified config
/// ready for `generateLiberty`. Caller loops over corners.
pub fn applyCorner(base: LibertyConfig, corner: CornerSpec) LibertyConfig {
    var cfg = base;
    cfg.nom_voltage = corner.nom_voltage;
    cfg.nom_temperature = corner.nom_temperature;
    cfg.nom_process = corner.name;
    cfg.model_corner = corner.model_corner;
    cfg.library_name = corner.name;
    return cfg;
}

// ─── Pull in all sub-module tests ───────────────────────────────────────────

comptime {
    _ = @import("types.zig");
    _ = @import("gds_area.zig");
    _ = @import("spice_sim.zig");
    _ = @import("writer.zig");
}

// ─── Integration test ───────────────────────────────────────────────────────

test "generateLiberty integration: synthetic cell produces valid Liberty" {
    const alloc = std.testing.allocator;
    const NldmTable = types.NldmTable;
    const PgPin = types.PgPin;
    var buf = std.ArrayList(u8).init(alloc);
    defer buf.deinit();

    const cr = try NldmTable.scalar(alloc, 7, 7, 0.045);
    defer cr.deinit(alloc);
    const cf = try NldmTable.scalar(alloc, 7, 7, 0.038);
    defer cf.deinit(alloc);
    const rt = try NldmTable.scalar(alloc, 7, 7, 0.032);
    defer rt.deinit(alloc);
    const ft = try NldmTable.scalar(alloc, 7, 7, 0.028);
    defer ft.deinit(alloc);
    const rp = try NldmTable.scalar(alloc, 7, 7, 0.0012);
    defer rp.deinit(alloc);
    const fp = try NldmTable.scalar(alloc, 7, 7, 0.0015);
    defer fp.deinit(alloc);

    const timing_arcs = try alloc.alloc(TimingArc, 1);
    defer alloc.free(timing_arcs);
    timing_arcs[0] = .{
        .related_pin = "INP",
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
        .related_pin = "INP",
        .rise_power = rp,
        .fall_power = fp,
    };

    const pg_pins = try alloc.alloc(PgPin, 2);
    defer alloc.free(pg_pins);
    pg_pins[0] = .{ .name = "VDD", .pg_type = .primary_power, .voltage_name = "VDD" };
    pg_pins[1] = .{ .name = "VSS", .pg_type = .primary_ground, .voltage_name = "VSS" };

    const pins = try alloc.alloc(LibertyPin, 2);
    defer alloc.free(pins);
    pins[0] = .{ .name = "INP", .direction = .input, .capacitance = 0.002, .max_capacitance = 0, .timing_arcs = &.{}, .internal_power = &.{} };
    pins[1] = .{ .name = "OUT", .direction = .output, .capacitance = 0, .max_capacitance = 0.1, .timing_arcs = timing_arcs, .internal_power = int_power };

    const cell = LibertyCell{
        .name = "current_mirror",
        .area = 125.6,
        .leakage_power = 0.85,
        .pins = pins,
        .pg_pins = pg_pins,
    };

    const config = LibertyConfig{};
    try writer.writeLiberty(buf.writer(), &cell, config);

    const output = buf.items;
    const testing = std.testing;

    try testing.expect(std.mem.indexOf(u8, output, "library(spout_analog)") != null);
    try testing.expect(std.mem.indexOf(u8, output, "technology (cmos)") != null);
    try testing.expect(std.mem.indexOf(u8, output, "cell(current_mirror)") != null);
    try testing.expect(std.mem.indexOf(u8, output, "area : 125.6") != null);
    try testing.expect(std.mem.indexOf(u8, output, "cell_leakage_power") != null);
    try testing.expect(std.mem.indexOf(u8, output, "voltage_map(VDD, 1.80)") != null);
    try testing.expect(std.mem.indexOf(u8, output, "voltage_map(VSS, 0.00)") != null);
    try testing.expect(std.mem.indexOf(u8, output, "lu_table_template(delay_template_7x7)") != null);
    try testing.expect(std.mem.indexOf(u8, output, "lu_table_template(power_template_7x7)") != null);
    try testing.expect(std.mem.indexOf(u8, output, "pg_pin(VDD)") != null);
    try testing.expect(std.mem.indexOf(u8, output, "pg_type : primary_power") != null);
    try testing.expect(std.mem.indexOf(u8, output, "pg_pin(VSS)") != null);
    try testing.expect(std.mem.indexOf(u8, output, "pg_type : primary_ground") != null);
    try testing.expect(std.mem.indexOf(u8, output, "pin(INP)") != null);
    try testing.expect(std.mem.indexOf(u8, output, "pin(OUT)") != null);
    try testing.expect(std.mem.indexOf(u8, output, "timing()") != null);
    try testing.expect(std.mem.indexOf(u8, output, "related_pin : \"INP\"") != null);
    try testing.expect(std.mem.indexOf(u8, output, "cell_rise(delay_template_7x7)") != null);
    try testing.expect(std.mem.indexOf(u8, output, "cell_fall(delay_template_7x7)") != null);
    try testing.expect(std.mem.indexOf(u8, output, "rise_transition(delay_template_7x7)") != null);
    try testing.expect(std.mem.indexOf(u8, output, "fall_transition(delay_template_7x7)") != null);
    try testing.expect(std.mem.indexOf(u8, output, "internal_power()") != null);
    try testing.expect(std.mem.indexOf(u8, output, "rise_power(power_template_7x7)") != null);
    try testing.expect(std.mem.indexOf(u8, output, "fall_power(power_template_7x7)") != null);
    try testing.expect(std.mem.indexOf(u8, output, "nom_voltage : 1.800") != null);
    try testing.expect(std.mem.indexOf(u8, output, "nom_temperature : 25.0") != null);
}
