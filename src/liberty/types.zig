// liberty/types.zig
//
// Data model for Liberty (.lib) file generation targeting mixed-signal
// OpenROAD.  These types represent the characterization data needed to
// describe an analog cell: area, pin capacitances, timing arcs, and power.
//
// Reference: Liberty format specification (Synopsys Liberty Reference Manual),
//            OpenROAD read_liberty requirements.

const std = @import("std");

// ─── Pin direction ──────────────────────────────────────────────────────────

pub const PinDirection = enum(u8) {
    input = 0,
    output = 1,
    inout = 2,
    internal = 3,

    pub fn asString(self: PinDirection) []const u8 {
        return switch (self) {
            .input => "input",
            .output => "output",
            .inout => "inout",
            .internal => "internal",
        };
    }
};

// ─── Timing sense ───────────────────────────────────────────────────────────

pub const TimingSense = enum(u8) {
    positive_unate = 0,
    negative_unate = 1,
    non_unate = 2,

    pub fn asString(self: TimingSense) []const u8 {
        return switch (self) {
            .positive_unate => "positive_unate",
            .negative_unate => "negative_unate",
            .non_unate => "non_unate",
        };
    }
};

// ─── Timing type ────────────────────────────────────────────────────────────

pub const TimingType = enum(u8) {
    combinational = 0,
    rising_edge = 1,
    falling_edge = 2,
    setup_rising = 3,
    setup_falling = 4,
    hold_rising = 5,
    hold_falling = 6,

    pub fn asString(self: TimingType) []const u8 {
        return switch (self) {
            .combinational => "combinational",
            .rising_edge => "rising_edge",
            .falling_edge => "falling_edge",
            .setup_rising => "setup_rising",
            .setup_falling => "setup_falling",
            .hold_rising => "hold_rising",
            .hold_falling => "hold_falling",
        };
    }
};

// ─── Power/Ground pin types ─────────────────────────────────────────────────

pub const PgPinType = enum(u8) {
    primary_power = 0,
    primary_ground = 1,
    nwell = 2,
    pwell = 3,

    pub fn asString(self: PgPinType) []const u8 {
        return switch (self) {
            .primary_power => "primary_power",
            .primary_ground => "primary_ground",
            .nwell => "nwell",
            .pwell => "pwell",
        };
    }
};

pub const PgPin = struct {
    name: []const u8,
    pg_type: PgPinType,
    voltage_name: []const u8,
};

// ─── NLDM 2D lookup table ──────────────────────────────────────────────────

pub const NLDM_SIZE: usize = 7;

pub const NldmTable = struct {
    /// 2D values [slew_idx][load_idx]. Rows = input slew, cols = output load.
    values: [NLDM_SIZE][NLDM_SIZE]f64,

    /// Create a table filled with a single scalar value.
    pub fn scalar(val: f64) NldmTable {
        var t: NldmTable = undefined;
        for (0..NLDM_SIZE) |i| {
            for (0..NLDM_SIZE) |j| {
                t.values[i][j] = val;
            }
        }
        return t;
    }
};

// ─── Timing arc ─────────────────────────────────────────────────────────────
//
// One directional path from related_pin → pin (the pin this arc belongs to).
// Contains NLDM 2D lookup tables indexed by (input_slew, output_load).

pub const TimingArc = struct {
    /// Name of the related (driving) pin.
    related_pin: []const u8,
    timing_sense: TimingSense,
    timing_type: TimingType,
    /// Propagation delay for rising output (ns). 2D: slew × load.
    cell_rise: NldmTable,
    /// Propagation delay for falling output (ns). 2D: slew × load.
    cell_fall: NldmTable,
    /// Output rise transition time 10%-90% (ns). 2D: slew × load.
    rise_transition: NldmTable,
    /// Output fall transition time 90%-10% (ns). 2D: slew × load.
    fall_transition: NldmTable,
    /// pg_pin supplying power for this arc (e.g. "VPWR").
    related_power_pin: ?[]const u8 = null,
    /// pg_pin supplying ground for this arc (e.g. "VGND").
    related_ground_pin: ?[]const u8 = null,
};

// ─── Power data ─────────────────────────────────────────────────────────────

pub const InternalPower = struct {
    /// Related pin driving the transition.
    related_pin: []const u8,
    /// Energy per rising transition (pJ). 2D: slew × load.
    rise_power: NldmTable,
    /// Energy per falling transition (pJ). 2D: slew × load.
    fall_power: NldmTable,
    /// pg_pin supplying power for this measurement (e.g. "VPWR").
    related_pg_pin: ?[]const u8 = null,
};

// ─── Pin ────────────────────────────────────────────────────────────────────

pub const LibertyPin = struct {
    name: []const u8,
    direction: PinDirection,
    /// Input capacitance (pF). For outputs, this is the max load cap tested.
    capacitance: f64,
    /// Max capacitance on this pin (pF). Output pins only.
    max_capacitance: f64,
    /// Timing arcs terminating at this pin.
    timing_arcs: []const TimingArc,
    /// Internal power entries for this pin.
    internal_power: []const InternalPower,
};

// ─── Cell ───────────────────────────────────────────────────────────────────

pub const LibertyCell = struct {
    name: []const u8,
    /// Cell area in µm².
    area: f64,
    /// Cell leakage power in nW.
    leakage_power: f64,
    /// Signal pins only (input/output/inout).
    pins: []const LibertyPin,
    /// Power/ground pins (VDD, VSS, wells).
    pg_pins: []const PgPin,
};

// ─── Configuration ──────────────────────────────────────────────────────────
//
// Parameters controlling characterization: operating conditions, PDK model
// paths, and simulation settings.

pub const LibertyConfig = struct {
    /// Nominal supply voltage (V). sky130 default = 1.8.
    nom_voltage: f64 = 1.8,
    /// Nominal temperature (°C). Default = 25.
    nom_temperature: f64 = 25.0,
    /// Process corner name (for Liberty header).
    nom_process: []const u8 = "typical",
    /// Time unit for Liberty file.
    time_unit: []const u8 = "1ns",
    /// Voltage unit.
    voltage_unit: []const u8 = "1V",
    /// Current unit.
    current_unit: []const u8 = "1uA",
    /// Capacitance unit.
    capacitive_load_unit: []const u8 = "1pf",
    /// Leakage power unit.
    leaking_power_unit: []const u8 = "1nW",
    /// Path to SPICE model library (e.g., sky130 tt corner).
    model_lib_path: []const u8 = "",
    /// Model corner section (e.g., "tt" for typical-typical).
    model_corner: []const u8 = "tt",
    /// Input slew rate for stimulus (ns). Rise/fall time of input waveform.
    input_slew_ns: f64 = 0.1,
    /// Output load capacitance for timing measurement (pF).
    output_load_pf: f64 = 0.005,
    /// Simulation time for transient analysis (ns).
    sim_time_ns: f64 = 50.0,
    /// Supply net name.
    vdd_net: []const u8 = "VDD",
    /// Ground net name.
    vss_net: []const u8 = "VSS",
    /// GDS database unit in µm (sky130 = 0.001).
    gds_db_unit_um: f64 = 0.001,
    /// Library name for Liberty header.
    library_name: []const u8 = "spout_analog",
    /// Slew breakpoints for NLDM tables (ns). Sky130 typical values.
    slew_indices: [NLDM_SIZE]f64 = .{ 0.0100, 0.0230, 0.0531, 0.1233, 0.2830, 0.6497, 1.5000 },
    /// Load breakpoints for NLDM tables (pF). Sky130 typical values.
    load_indices: [NLDM_SIZE]f64 = .{ 0.0005, 0.0012, 0.0030, 0.0074, 0.0181, 0.0445, 0.1093 },
};

// ─── Tests ──────────────────────────────────────────────────────────────────

test "PinDirection asString" {
    try std.testing.expectEqualStrings("input", PinDirection.input.asString());
    try std.testing.expectEqualStrings("output", PinDirection.output.asString());
    try std.testing.expectEqualStrings("inout", PinDirection.inout.asString());
}

test "TimingSense asString" {
    try std.testing.expectEqualStrings("positive_unate", TimingSense.positive_unate.asString());
    try std.testing.expectEqualStrings("negative_unate", TimingSense.negative_unate.asString());
    try std.testing.expectEqualStrings("non_unate", TimingSense.non_unate.asString());
}

test "TimingType asString" {
    try std.testing.expectEqualStrings("combinational", TimingType.combinational.asString());
    try std.testing.expectEqualStrings("rising_edge", TimingType.rising_edge.asString());
}

test "LibertyConfig defaults" {
    const cfg = LibertyConfig{};
    try std.testing.expectEqual(@as(f64, 1.8), cfg.nom_voltage);
    try std.testing.expectEqual(@as(f64, 25.0), cfg.nom_temperature);
    try std.testing.expectEqualStrings("typical", cfg.nom_process);
    try std.testing.expectEqualStrings("1ns", cfg.time_unit);
}

test "LibertyCell fields" {
    const cell = LibertyCell{
        .name = "test_cell",
        .area = 100.5,
        .leakage_power = 0.01,
        .pins = &.{},
        .pg_pins = &.{},
    };
    try std.testing.expectEqualStrings("test_cell", cell.name);
    try std.testing.expectEqual(@as(f64, 100.5), cell.area);
}

test "PgPinType asString" {
    try std.testing.expectEqualStrings("primary_power", PgPinType.primary_power.asString());
    try std.testing.expectEqualStrings("primary_ground", PgPinType.primary_ground.asString());
    try std.testing.expectEqualStrings("nwell", PgPinType.nwell.asString());
    try std.testing.expectEqualStrings("pwell", PgPinType.pwell.asString());
}

test "NldmTable scalar" {
    const t = NldmTable.scalar(0.05);
    try std.testing.expectEqual(@as(f64, 0.05), t.values[0][0]);
    try std.testing.expectEqual(@as(f64, 0.05), t.values[3][4]);
    try std.testing.expectEqual(@as(f64, 0.05), t.values[6][6]);
}

test "TimingArc fields" {
    const arc = TimingArc{
        .related_pin = "A",
        .timing_sense = .negative_unate,
        .timing_type = .combinational,
        .cell_rise = NldmTable.scalar(0.05),
        .cell_fall = NldmTable.scalar(0.04),
        .rise_transition = NldmTable.scalar(0.03),
        .fall_transition = NldmTable.scalar(0.02),
    };
    try std.testing.expectEqualStrings("A", arc.related_pin);
    try std.testing.expectEqual(TimingSense.negative_unate, arc.timing_sense);
    try std.testing.expectEqual(@as(f64, 0.05), arc.cell_rise.values[0][0]);
}
