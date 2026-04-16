// liberty/pdk.zig
//
// Volare PDK corner support for Liberty generation.
//
// Provides comptime-defined PDK data models (sky130, gf180mcu) and runtime
// helpers for path construction and corner enumeration.  No filesystem I/O
// is performed here — directory scanning is a future enhancement.
//
// Usage:
//   const pdk = @import("pdk.zig");
//   const cs = pdk.fromName("sky130") orelse return error.UnknownPdk;
//   const corners = try cs.generateCorners(allocator);

const std = @import("std");
const lib = @import("lib.zig");
const CornerSpec = lib.CornerSpec;

// ─── PDK identity ────────────────────────────────────────────────────────────

pub const PdkId = enum {
    sky130,
    gf180mcu,
};

// ─── Voltage domain ──────────────────────────────────────────────────────────

pub const VoltageDomain = struct {
    /// Short label, e.g. "1v8" or "3v3".
    name: []const u8,
    /// Nominal voltages for ss / tt / ff respectively (V).
    nom_voltages: []const f64,
};

// ─── PdkCornerSet ────────────────────────────────────────────────────────────

pub const PdkCornerSet = struct {
    pdk: PdkId,
    /// Relative path from PDK root to model library directory.
    /// E.g. "libs.tech/ngspice"
    model_lib_dir: []const u8,
    /// Model file name within model_lib_dir.
    /// sky130: "sky130.lib.spice"  gf180mcu: "sm141064.ngspice"
    model_file: []const u8,
    /// Corner section names used in .lib include statements.
    corner_names: []const []const u8,
    /// Voltage domains available for this PDK.
    voltage_domains: []const VoltageDomain,
    /// Temperature sweep points (°C).
    temperatures: []const f64,
    /// Power pin names (case-insensitive match).
    power_pin_names: []const []const u8,
    /// Ground pin names (case-insensitive match).
    ground_pin_names: []const []const u8,
    /// N-well bias pin names (empty if PDK has no well bias pins).
    nwell_pin_names: []const []const u8,
    /// P-well bias pin names (empty if PDK has no well bias pins).
    pwell_pin_names: []const []const u8,
    /// Supply net name for Liberty voltage_map.
    vdd_net: []const u8,
    /// Ground net name for Liberty voltage_map.
    vss_net: []const u8,

    /// Build the full path to the model library file.
    /// `buf` must be large enough for the resulting path.
    /// Returns a slice into `buf`.
    pub fn modelLibPath(
        self: PdkCornerSet,
        pdk_root: []const u8,
        pdk_variant: []const u8,
        buf: []u8,
    ) []const u8 {
        return std.fmt.bufPrint(buf, "{s}/{s}/{s}/{s}", .{
            pdk_root, pdk_variant, self.model_lib_dir, self.model_file,
        }) catch buf[0..0];
    }

    /// Generate all PVT corners: corner_name × voltage × temperature.
    /// Caller owns the returned slice and must free it.
    pub fn generateCorners(
        self: PdkCornerSet,
        allocator: std.mem.Allocator,
    ) ![]CornerSpec {
        // Pick the first voltage domain as default for cross-product generation.
        const domain = if (self.voltage_domains.len > 0)
            self.voltage_domains[0]
        else
            return allocator.alloc(CornerSpec, 0);

        const n = self.corner_names.len * domain.nom_voltages.len * self.temperatures.len;
        const corners = try allocator.alloc(CornerSpec, n);
        var idx: usize = 0;

        for (self.corner_names) |cname| {
            for (domain.nom_voltages) |voltage| {
                for (self.temperatures) |temp| {
                    // Format a canonical name, e.g. "tt_025C_1v80"
                    // Encode temperature with sign: n40C, 025C, 100C, 125C
                    var name_buf: [64]u8 = undefined;
                    const name = formatCornerName(&name_buf, cname, voltage, temp);
                    corners[idx] = .{
                        .name = try allocator.dupe(u8, name),
                        .model_corner = cname,
                        .nom_voltage = voltage,
                        .nom_temperature = temp,
                    };
                    idx += 1;
                }
            }
        }

        return corners;
    }

    /// Classify a port name using this PDK's pin name lists.
    /// Returns the PortRole appropriate for SPICE testbench generation.
    pub fn classifyPortForPdk(self: PdkCornerSet, name: []const u8) PortRole {
        for (self.nwell_pin_names) |n| {
            if (std.ascii.eqlIgnoreCase(name, n)) return .nwell;
        }
        for (self.pwell_pin_names) |n| {
            if (std.ascii.eqlIgnoreCase(name, n)) return .pwell;
        }
        for (self.power_pin_names) |n| {
            if (std.ascii.eqlIgnoreCase(name, n)) return .vdd;
        }
        for (self.ground_pin_names) |n| {
            if (std.ascii.eqlIgnoreCase(name, n)) return .vss;
        }
        // Fall through to heuristic signal classification.
        return classifySignalPort(name);
    }
};

// ─── PortRole (mirrored from spice_sim.zig for PDK-aware classification) ─────

pub const PortRole = enum {
    vdd,
    vss,
    nwell,
    pwell,
    signal_in,
    signal_out,
    signal_inout,
};

/// Heuristic signal port classification (no PDK context needed).
pub fn classifySignalPort(name: []const u8) PortRole {
    if (containsIgnoreCase(name, "OUT") or containsIgnoreCase(name, "VOUT"))
        return .signal_out;
    if (name.len == 1 and (name[0] == 'Y' or name[0] == 'Q' or
        name[0] == 'y' or name[0] == 'q'))
        return .signal_out;
    return .signal_in;
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (haystack.len < needle.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle))
            return true;
    }
    return false;
}

// ─── Corner name formatting ───────────────────────────────────────────────────

/// Format a Liberty-style corner name, e.g. "tt_025C_1v80".
/// Writes into `buf` and returns a slice of the written bytes.
fn formatCornerName(buf: []u8, corner: []const u8, voltage: f64, temp: f64) []const u8 {
    // Encode temperature: negative -> "n40C", positive -> "025C"
    var temp_buf: [16]u8 = undefined;
    const temp_str = formatTemp(&temp_buf, temp);

    // Encode voltage: 1.80 -> "1v80"
    var volt_buf: [16]u8 = undefined;
    const volt_str = formatVolt(&volt_buf, voltage);

    return std.fmt.bufPrint(buf, "{s}_{s}_{s}", .{ corner, temp_str, volt_str }) catch buf[0..0];
}

fn formatTemp(buf: []u8, temp: f64) []const u8 {
    if (temp < 0.0) {
        const abs_t: u32 = @intFromFloat(@abs(temp));
        return std.fmt.bufPrint(buf, "n{d:0>2}C", .{abs_t}) catch buf[0..0];
    } else {
        const t: u32 = @intFromFloat(temp);
        return std.fmt.bufPrint(buf, "{d:0>3}C", .{t}) catch buf[0..0];
    }
}

fn formatVolt(buf: []u8, voltage: f64) []const u8 {
    // Represent as integer whole + two-digit frac, separated by 'v'.
    // E.g. 1.80 -> "1v80", 3.30 -> "3v30", 1.62 -> "1v62"
    const whole: u32 = @intFromFloat(voltage);
    const frac: u32 = @intFromFloat(@round((voltage - @as(f64, @floatFromInt(whole))) * 100.0));
    return std.fmt.bufPrint(buf, "{d}v{d:0>2}", .{ whole, frac }) catch buf[0..0];
}

// ─── Comptime PDK definitions ─────────────────────────────────────────────────

const sky130_corner_names = [_][]const u8{ "tt", "ss", "ff", "sf", "fs" };
const sky130_nom_voltages = [_]f64{ 1.60, 1.80, 1.95 };
const sky130_temps = [_]f64{ -40.0, 25.0, 100.0 };
const sky130_power_pins = [_][]const u8{ "VPWR", "VDD", "VDDA", "AVDD" };
const sky130_ground_pins = [_][]const u8{ "VGND", "VSS", "VSSA", "AVSS", "GND" };
const sky130_nwell_pins = [_][]const u8{"VPB"};
const sky130_pwell_pins = [_][]const u8{"VNB"};
const sky130_voltage_domain = VoltageDomain{
    .name = "1v8",
    .nom_voltages = &sky130_nom_voltages,
};
const sky130_voltage_domains = [_]VoltageDomain{sky130_voltage_domain};

/// sky130 PDK corner set (sky130A / sky130B variants share the same corners).
pub const sky130 = PdkCornerSet{
    .pdk = .sky130,
    .model_lib_dir = "libs.tech/ngspice",
    .model_file = "sky130.lib.spice",
    .corner_names = &sky130_corner_names,
    .voltage_domains = &sky130_voltage_domains,
    .temperatures = &sky130_temps,
    .power_pin_names = &sky130_power_pins,
    .ground_pin_names = &sky130_ground_pins,
    .nwell_pin_names = &sky130_nwell_pins,
    .pwell_pin_names = &sky130_pwell_pins,
    .vdd_net = "VPWR",
    .vss_net = "VGND",
};

// gf180mcu 3.3 V domain
const gf180_corner_names = [_][]const u8{ "tt", "ss", "ff", "sf", "fs" };
const gf180_3v3_voltages = [_]f64{ 3.0, 3.3, 3.6 };
const gf180_1v8_voltages = [_]f64{ 1.62, 1.80, 1.98 };
const gf180_temps = [_]f64{ -40.0, 25.0, 125.0 };
const gf180_power_pins = [_][]const u8{ "VDD", "VDDA", "AVDD" };
const gf180_ground_pins = [_][]const u8{ "VSS", "VSSA", "AVSS", "GND" };
const gf180_nwell_pins = [_][]const u8{};
const gf180_pwell_pins = [_][]const u8{};
const gf180_3v3_domain = VoltageDomain{
    .name = "3v3",
    .nom_voltages = &gf180_3v3_voltages,
};
const gf180_1v8_domain = VoltageDomain{
    .name = "1v8",
    .nom_voltages = &gf180_1v8_voltages,
};
const gf180_3v3_domains = [_]VoltageDomain{gf180_3v3_domain};
const gf180_1v8_domains = [_]VoltageDomain{gf180_1v8_domain};

/// gf180mcu 3.3 V domain corner set.
pub const gf180mcu_3v3 = PdkCornerSet{
    .pdk = .gf180mcu,
    .model_lib_dir = "libs.tech/ngspice",
    .model_file = "sm141064.ngspice",
    .corner_names = &gf180_corner_names,
    .voltage_domains = &gf180_3v3_domains,
    .temperatures = &gf180_temps,
    .power_pin_names = &gf180_power_pins,
    .ground_pin_names = &gf180_ground_pins,
    .nwell_pin_names = &gf180_nwell_pins,
    .pwell_pin_names = &gf180_pwell_pins,
    .vdd_net = "VDD",
    .vss_net = "VSS",
};

/// gf180mcu 1.8 V domain corner set.
pub const gf180mcu_1v8 = PdkCornerSet{
    .pdk = .gf180mcu,
    .model_lib_dir = "libs.tech/ngspice",
    .model_file = "sm141064.ngspice",
    .corner_names = &gf180_corner_names,
    .voltage_domains = &gf180_1v8_domains,
    .temperatures = &gf180_temps,
    .power_pin_names = &gf180_power_pins,
    .ground_pin_names = &gf180_ground_pins,
    .nwell_pin_names = &gf180_nwell_pins,
    .pwell_pin_names = &gf180_pwell_pins,
    .vdd_net = "VDD",
    .vss_net = "VSS",
};

// ─── Lookup helpers ───────────────────────────────────────────────────────────

/// Look up a PdkCornerSet by name string.
/// Recognised names: "sky130", "gf180mcu_3v3", "gf180mcu_1v8".
/// Returns null for unrecognised names.
pub fn fromName(name: []const u8) ?*const PdkCornerSet {
    if (std.ascii.eqlIgnoreCase(name, "sky130")) return &sky130;
    if (std.ascii.eqlIgnoreCase(name, "gf180mcu_3v3")) return &gf180mcu_3v3;
    if (std.ascii.eqlIgnoreCase(name, "gf180mcu_1v8")) return &gf180mcu_1v8;
    // Also accept bare "gf180mcu" -> default to 3v3 domain
    if (std.ascii.eqlIgnoreCase(name, "gf180mcu")) return &gf180mcu_3v3;
    return null;
}

/// Attempt to detect the PDK from `$PDK_ROOT` and `$PDK` environment variables.
/// Returns a pointer to a comptime constant on success, null if env is unset or
/// the PDK is not recognised.
pub fn detectFromEnv() ?*const PdkCornerSet {
    const pdk_name = std.process.getEnvVarOwned(std.heap.page_allocator, "PDK") catch return null;
    defer std.heap.page_allocator.free(pdk_name);
    return fromName(pdk_name);
}

// ─── Tests ───────────────────────────────────────────────────────────────────

test "fromName sky130" {
    const cs = fromName("sky130");
    try std.testing.expect(cs != null);
    try std.testing.expectEqual(PdkId.sky130, cs.?.pdk);
}

test "fromName gf180mcu variants" {
    const cs3 = fromName("gf180mcu_3v3");
    try std.testing.expect(cs3 != null);
    try std.testing.expectEqual(PdkId.gf180mcu, cs3.?.pdk);

    const cs1 = fromName("gf180mcu_1v8");
    try std.testing.expect(cs1 != null);
    try std.testing.expectEqual(PdkId.gf180mcu, cs1.?.pdk);

    // Bare name resolves to 3v3 default
    const cs_bare = fromName("gf180mcu");
    try std.testing.expect(cs_bare != null);
    try std.testing.expectEqualStrings("3v3", cs_bare.?.voltage_domains[0].name);
}

test "fromName unknown" {
    try std.testing.expect(fromName("tsmc28") == null);
    try std.testing.expect(fromName("") == null);
}

test "generateCorners sky130 count" {
    const allocator = std.testing.allocator;
    const cs = fromName("sky130").?;
    const corners = try cs.generateCorners(allocator);
    defer {
        for (corners) |c| allocator.free(c.name);
        allocator.free(corners);
    }
    // 5 corners × 3 voltages × 3 temps = 45
    try std.testing.expectEqual(@as(usize, 45), corners.len);
}

test "generateCorners gf180mcu_3v3 count" {
    const allocator = std.testing.allocator;
    const cs = fromName("gf180mcu_3v3").?;
    const corners = try cs.generateCorners(allocator);
    defer {
        for (corners) |c| allocator.free(c.name);
        allocator.free(corners);
    }
    // 5 corners × 3 voltages × 3 temps = 45
    try std.testing.expectEqual(@as(usize, 45), corners.len);
}

test "generateCorners names formatted correctly" {
    const allocator = std.testing.allocator;
    const cs = fromName("sky130").?;
    const corners = try cs.generateCorners(allocator);
    defer {
        for (corners) |c| allocator.free(c.name);
        allocator.free(corners);
    }
    // First corner: tt, -40 °C, 1.60 V -> "tt_n40C_1v60"
    try std.testing.expectEqualStrings("tt_n40C_1v60", corners[0].name);
    // Second: tt, 25 °C, 1.60 V -> "tt_025C_1v60"
    try std.testing.expectEqualStrings("tt_025C_1v60", corners[1].name);
    // Third: tt, 100 °C, 1.60 V -> "tt_100C_1v60"
    try std.testing.expectEqualStrings("tt_100C_1v60", corners[2].name);
}

test "classifyPortForPdk sky130 pins" {
    const cs = fromName("sky130").?;
    try std.testing.expectEqual(PortRole.vdd, cs.classifyPortForPdk("VPWR"));
    try std.testing.expectEqual(PortRole.vdd, cs.classifyPortForPdk("vpwr"));
    try std.testing.expectEqual(PortRole.vss, cs.classifyPortForPdk("VGND"));
    try std.testing.expectEqual(PortRole.nwell, cs.classifyPortForPdk("VPB"));
    try std.testing.expectEqual(PortRole.pwell, cs.classifyPortForPdk("VNB"));
    try std.testing.expectEqual(PortRole.signal_in, cs.classifyPortForPdk("INP"));
    try std.testing.expectEqual(PortRole.signal_out, cs.classifyPortForPdk("OUT"));
}

test "classifyPortForPdk gf180mcu no well pins" {
    const cs = fromName("gf180mcu_3v3").?;
    try std.testing.expectEqual(PortRole.vdd, cs.classifyPortForPdk("VDD"));
    try std.testing.expectEqual(PortRole.vss, cs.classifyPortForPdk("VSS"));
    // gf180mcu has no VPB/VNB — they should fall through to signal_in
    try std.testing.expectEqual(PortRole.signal_in, cs.classifyPortForPdk("VPB"));
    try std.testing.expectEqual(PortRole.signal_in, cs.classifyPortForPdk("VNB"));
}

test "modelLibPath sky130" {
    const cs = fromName("sky130").?;
    var buf: [256]u8 = undefined;
    const path = cs.modelLibPath("/home/user/.volare", "sky130A", &buf);
    try std.testing.expectEqualStrings(
        "/home/user/.volare/sky130A/libs.tech/ngspice/sky130.lib.spice",
        path,
    );
}

test "modelLibPath gf180mcu" {
    const cs = fromName("gf180mcu_3v3").?;
    var buf: [256]u8 = undefined;
    const path = cs.modelLibPath("/pdk", "gf180mcuA", &buf);
    try std.testing.expectEqualStrings(
        "/pdk/gf180mcuA/libs.tech/ngspice/sm141064.ngspice",
        path,
    );
}

test "formatVolt edge cases" {
    var buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("1v80", formatVolt(&buf, 1.80));
    try std.testing.expectEqualStrings("1v60", formatVolt(&buf, 1.60));
    try std.testing.expectEqualStrings("1v95", formatVolt(&buf, 1.95));
    try std.testing.expectEqualStrings("3v30", formatVolt(&buf, 3.30));
    try std.testing.expectEqualStrings("1v62", formatVolt(&buf, 1.62));
}

test "formatTemp" {
    var buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("n40C", formatTemp(&buf, -40.0));
    try std.testing.expectEqualStrings("025C", formatTemp(&buf, 25.0));
    try std.testing.expectEqualStrings("100C", formatTemp(&buf, 100.0));
    try std.testing.expectEqualStrings("125C", formatTemp(&buf, 125.0));
}
