// liberty/spice_sim.zig
//
// ngspice simulation harness for analog cell characterization.
//
// Generates ngspice testbench decks, runs them in batch mode, and parses
// .measure output for timing (propagation delay, slew) and power (leakage
// current).  Used by the Liberty generator to characterize analog cells.
//
// Flow:
//   1. Parse SPICE netlist to identify .subckt ports
//   2. Classify ports as input/output/power by name heuristics
//   3. Generate DC deck -> measure leakage (Idd at quiescent)
//   4. Generate transient deck per input->output arc -> measure tpd, trise, tfall
//   5. Parse ngspice stdout for .measure results

const std = @import("std");
const types = @import("types.zig");

const LibertyConfig = types.LibertyConfig;
const LibertyPin = types.LibertyPin;
const TimingArc = types.TimingArc;
const InternalPower = types.InternalPower;
const PinDirection = types.PinDirection;
const TimingSense = types.TimingSense;
const TimingType = types.TimingType;
const PgPin = types.PgPin;
const PgPinType = types.PgPinType;
const NldmTable = types.NldmTable;

// ─── Port classification ────────────────────────────────────────────────────

const PortRole = enum {
    vdd,
    vss,
    nwell,
    pwell,
    signal_in,
    signal_out,
    signal_inout,
};

const PortInfo = struct {
    name: []const u8,
    role: PortRole,
};

fn classifyPort(name: []const u8) PortRole {
    // Well-bias pins (distinct from main supply)
    if (std.ascii.eqlIgnoreCase(name, "VPB"))
        return .nwell;
    if (std.ascii.eqlIgnoreCase(name, "VNB"))
        return .pwell;

    if (std.ascii.eqlIgnoreCase(name, "VDD") or
        std.ascii.eqlIgnoreCase(name, "VPWR") or
        std.ascii.eqlIgnoreCase(name, "VDDA") or
        std.ascii.eqlIgnoreCase(name, "AVDD"))
        return .vdd;

    if (std.ascii.eqlIgnoreCase(name, "VSS") or
        std.ascii.eqlIgnoreCase(name, "VGND") or
        std.ascii.eqlIgnoreCase(name, "GND") or
        std.ascii.eqlIgnoreCase(name, "VSSA") or
        std.ascii.eqlIgnoreCase(name, "AVSS"))
        return .vss;

    if (containsIgnoreCase(name, "OUT") or
        containsIgnoreCase(name, "VOUT"))
        return .signal_out;

    // Single-letter Y/Q common for digital-style outputs
    if (name.len == 1 and (name[0] == 'Y' or name[0] == 'Q' or name[0] == 'y' or name[0] == 'q'))
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

// ─── SPICE netlist parser (minimal) ─────────────────────────────────────────

fn parseSubcktPorts(allocator: std.mem.Allocator, spice_content: []const u8, cell_name: []const u8) ![]PortInfo {
    var ports = std.ArrayList(PortInfo).init(allocator);
    errdefer ports.deinit();

    var lines = std.mem.splitScalar(u8, spice_content, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len < 7) continue;
        if (!std.ascii.eqlIgnoreCase(trimmed[0..7], ".subckt")) continue;

        var tokens = std.mem.tokenizeAny(u8, trimmed[7..], " \t");
        const name = tokens.next() orelse continue;
        if (!std.ascii.eqlIgnoreCase(name, cell_name)) continue;

        while (tokens.next()) |tok| {
            if (std.mem.indexOfScalar(u8, tok, '=') != null) break;
            if (tok[0] == '*' or tok[0] == '$') break;
            try ports.append(.{ .name = tok, .role = classifyPort(tok) });
        }
        break;
    }

    return ports.toOwnedSlice();
}

// ─── Simulation context ─────────────────────────────────────────────────────

pub const SimContext = struct {
    allocator: std.mem.Allocator,
    spice_content: []u8,
    cell_name: []const u8,
    config: LibertyConfig,
    ports: []PortInfo,

    pub fn init(
        allocator: std.mem.Allocator,
        spice_path: []const u8,
        cell_name: []const u8,
        config: LibertyConfig,
    ) !SimContext {
        const file = try std.fs.cwd().openFile(spice_path, .{});
        defer file.close();
        const stat = try file.stat();
        const content = try allocator.alloc(u8, stat.size);
        errdefer allocator.free(content);
        const bytes_read = try file.readAll(content);
        const spice_content = content[0..bytes_read];

        const ports = try parseSubcktPorts(allocator, spice_content, cell_name);

        return .{
            .allocator = allocator,
            .spice_content = content,
            .cell_name = cell_name,
            .config = config,
            .ports = ports,
        };
    }

    pub fn deinit(self: *SimContext) void {
        self.allocator.free(self.ports);
        self.allocator.free(self.spice_content);
        self.* = undefined;
    }

    /// Run DC operating point to measure leakage power (nW).
    pub fn measureLeakagePower(self: *SimContext) !f64 {
        var deck = std.ArrayList(u8).init(self.allocator);
        defer deck.deinit();
        const w = deck.writer();

        try self.writeDeckHeader(w);

        // Bias all signal inputs at mid-rail for quiescent operating point
        for (self.ports) |port| {
            if (port.role == .signal_in or port.role == .signal_inout) {
                try w.print("v_bias_{s} {s} 0 dc {d:.3}\n", .{ port.name, port.name, self.config.nom_voltage / 2.0 });
            }
        }

        try w.writeAll(
            \\
            \\.control
            \\op
            \\let i_leak = abs(i(vvdd))
            \\echo "MEAS_LEAK=$&i_leak"
            \\quit
            \\.endc
            \\.end
            \\
        );

        const output = try self.runNgspice(deck.items);
        defer self.allocator.free(output);

        const i_leak = parseNamedValue(output, "MEAS_LEAK=") orelse 1.0e-12;
        return i_leak * self.config.nom_voltage * 1.0e9; // V * A -> W -> nW
    }

    pub const CharacterizationResult = struct {
        pins: []LibertyPin,
        pg_pins: []PgPin,
    };

    /// Characterize all pins: pg_pins for power, signal pins with NLDM timing.
    pub fn characterizePins(self: *SimContext, allocator: std.mem.Allocator) !CharacterizationResult {
        var pin_list = std.ArrayList(LibertyPin).init(allocator);
        errdefer pin_list.deinit();
        var pg_list = std.ArrayList(PgPin).init(allocator);
        errdefer pg_list.deinit();

        var inputs = std.ArrayList([]const u8).init(self.allocator);
        defer inputs.deinit();
        var outputs = std.ArrayList([]const u8).init(self.allocator);
        defer outputs.deinit();

        var pwr_pin_name: ?[]const u8 = null;
        var gnd_pin_name: ?[]const u8 = null;

        for (self.ports) |port| {
            switch (port.role) {
                .signal_in => try inputs.append(port.name),
                .signal_out => try outputs.append(port.name),
                .signal_inout => {
                    try inputs.append(port.name);
                    try outputs.append(port.name);
                },
                .vdd => {
                    if (pwr_pin_name == null) pwr_pin_name = port.name;
                    try pg_list.append(.{
                        .name = port.name,
                        .pg_type = .primary_power,
                        .voltage_name = self.config.vdd_net,
                    });
                },
                .vss => {
                    if (gnd_pin_name == null) gnd_pin_name = port.name;
                    try pg_list.append(.{
                        .name = port.name,
                        .pg_type = .primary_ground,
                        .voltage_name = self.config.vss_net,
                    });
                },
                .nwell => try pg_list.append(.{
                    .name = port.name,
                    .pg_type = .nwell,
                    .voltage_name = self.config.vdd_net,
                }),
                .pwell => try pg_list.append(.{
                    .name = port.name,
                    .pg_type = .pwell,
                    .voltage_name = self.config.vss_net,
                }),
            }
        }

        // Input pins with capacitance
        for (inputs.items) |inp| {
            const cap = try self.measureInputCap(inp);
            try pin_list.append(.{
                .name = inp,
                .direction = .input,
                .capacitance = cap,
                .max_capacitance = 0.0,
                .timing_arcs = &.{},
                .internal_power = &.{},
            });
        }

        // Output pins with NLDM timing arcs from each input
        for (outputs.items) |outp| {
            var arcs = std.ArrayList(TimingArc).init(allocator);
            errdefer arcs.deinit();
            var powers = std.ArrayList(InternalPower).init(allocator);
            errdefer powers.deinit();

            for (inputs.items) |inp| {
                var result = try self.measureTimingArc(allocator, inp, outp);
                result.arc.related_power_pin = pwr_pin_name;
                result.arc.related_ground_pin = gnd_pin_name;
                result.power.related_pg_pin = pwr_pin_name;
                try arcs.append(result.arc);
                try powers.append(result.power);
            }

            try pin_list.append(.{
                .name = outp,
                .direction = .output,
                .capacitance = 0.0,
                .max_capacitance = self.config.load_indices[self.config.load_indices.len - 1],
                .timing_arcs = try arcs.toOwnedSlice(),
                .internal_power = try powers.toOwnedSlice(),
            });
        }

        return .{
            .pins = try pin_list.toOwnedSlice(),
            .pg_pins = try pg_list.toOwnedSlice(),
        };
    }

    // ── Internal ─────────────────────────────────────────────────────────────

    const TimingResult = struct {
        arc: TimingArc,
        power: InternalPower,
    };

    /// Single-point measurement at given slew and load.
    const PointResult = struct {
        tpd_rise_ns: f64,
        tpd_fall_ns: f64,
        t_rise_ns: f64,
        t_fall_ns: f64,
        rise_pj: f64,
        fall_pj: f64,
    };

    fn measureSinglePoint(
        self: *SimContext,
        input_pin: []const u8,
        output_pin: []const u8,
        slew_ns: f64,
        load_pf: f64,
    ) !PointResult {
        var deck = std.ArrayList(u8).init(self.allocator);
        defer deck.deinit();
        const w = deck.writer();

        try self.writeDeckHeader(w);

        const vdd = self.config.nom_voltage;
        const sim_t = self.config.sim_time_ns;
        const half = sim_t / 4.0;

        // Pulse on input_pin with specified slew
        try w.print("vpulse {s} 0 pulse(0 {d:.3} {d:.3}n {d:.3}n {d:.3}n {d:.3}n {d:.3}n)\n", .{
            input_pin, vdd, half / 2.0, slew_ns, slew_ns, half, sim_t,
        });

        // Bias other signal inputs at mid-rail
        for (self.ports) |port| {
            if (port.role == .signal_in and !std.mem.eql(u8, port.name, input_pin)) {
                try w.print("v_bias_{s} {s} 0 dc {d:.3}\n", .{ port.name, port.name, vdd / 2.0 });
            }
        }

        // Load cap on output with specified load
        try w.print("cload {s} 0 {d:.6}p\n\n", .{ output_pin, load_pf });

        const thresh_mid = vdd * 0.5;
        const thresh_lo = vdd * 0.1;
        const thresh_hi = vdd * 0.9;
        const tstep = sim_t / 10000.0;

        try w.writeAll("\n.control\n");
        try w.print("tran {d:.6}n {d:.1}n\n", .{ tstep, sim_t });

        try w.print("meas tran tpd_rise trig v({s}) val={d:.4} rise=1 targ v({s}) val={d:.4} rise=1\n", .{
            input_pin, thresh_mid, output_pin, thresh_mid,
        });
        try w.print("meas tran tpd_fall trig v({s}) val={d:.4} fall=1 targ v({s}) val={d:.4} fall=1\n", .{
            input_pin, thresh_mid, output_pin, thresh_mid,
        });
        try w.print("meas tran t_rise trig v({s}) val={d:.4} rise=1 targ v({s}) val={d:.4} rise=1\n", .{
            output_pin, thresh_lo, output_pin, thresh_hi,
        });
        try w.print("meas tran t_fall trig v({s}) val={d:.4} fall=1 targ v({s}) val={d:.4} fall=1\n", .{
            output_pin, thresh_hi, output_pin, thresh_lo,
        });

        try w.print("meas tran iavg_rise avg i(vvdd) from={d:.4}n to={d:.4}n\n", .{ half * 0.4, half * 0.6 });
        try w.print("meas tran iavg_fall avg i(vvdd) from={d:.4}n to={d:.4}n\n", .{ half * 1.4, half * 1.6 });

        try w.writeAll(
            \\echo "MEAS_TPD_RISE=$&tpd_rise"
            \\echo "MEAS_TPD_FALL=$&tpd_fall"
            \\echo "MEAS_T_RISE=$&t_rise"
            \\echo "MEAS_T_FALL=$&t_fall"
            \\echo "MEAS_IAVG_RISE=$&iavg_rise"
            \\echo "MEAS_IAVG_FALL=$&iavg_fall"
            \\quit
            \\.endc
            \\.end
            \\
        );

        const output = try self.runNgspice(deck.items);
        defer self.allocator.free(output);

        const tpd_rise_ns = @abs(parseNamedValue(output, "MEAS_TPD_RISE=") orelse 1.0e-9) * 1.0e9;
        const tpd_fall_ns = @abs(parseNamedValue(output, "MEAS_TPD_FALL=") orelse 1.0e-9) * 1.0e9;
        const t_rise_ns = @abs(parseNamedValue(output, "MEAS_T_RISE=") orelse 1.0e-10) * 1.0e9;
        const t_fall_ns = @abs(parseNamedValue(output, "MEAS_T_FALL=") orelse 1.0e-10) * 1.0e9;
        const iavg_rise = @abs(parseNamedValue(output, "MEAS_IAVG_RISE=") orelse 1.0e-6);
        const iavg_fall = @abs(parseNamedValue(output, "MEAS_IAVG_FALL=") orelse 1.0e-6);

        const dt_ns = slew_ns * 2.0;
        return .{
            .tpd_rise_ns = tpd_rise_ns,
            .tpd_fall_ns = tpd_fall_ns,
            .t_rise_ns = t_rise_ns,
            .t_fall_ns = t_fall_ns,
            .rise_pj = vdd * iavg_rise * dt_ns * 1.0e-9 * 1.0e12,
            .fall_pj = vdd * iavg_fall * dt_ns * 1.0e-9 * 1.0e12,
        };
    }

    /// Sweep slew × load to produce NLDM timing tables.
    fn measureTimingArc(self: *SimContext, allocator: std.mem.Allocator, input_pin: []const u8, output_pin: []const u8) !TimingResult {
        const slew_count = self.config.slew_indices.len;
        const load_count = self.config.load_indices.len;

        var arc = TimingArc{
            .related_pin = input_pin,
            .timing_sense = .non_unate, // conservative default for analog
            .timing_type = .combinational,
            .cell_rise = try NldmTable.init(allocator, slew_count, load_count),
            .cell_fall = try NldmTable.init(allocator, slew_count, load_count),
            .rise_transition = try NldmTable.init(allocator, slew_count, load_count),
            .fall_transition = try NldmTable.init(allocator, slew_count, load_count),
        };
        errdefer {
            arc.cell_rise.deinit(allocator);
            arc.cell_fall.deinit(allocator);
            arc.rise_transition.deinit(allocator);
            arc.fall_transition.deinit(allocator);
        }

        var pwr = InternalPower{
            .related_pin = input_pin,
            .rise_power = try NldmTable.init(allocator, slew_count, load_count),
            .fall_power = try NldmTable.init(allocator, slew_count, load_count),
        };
        errdefer {
            pwr.rise_power.deinit(allocator);
            pwr.fall_power.deinit(allocator);
        }

        for (self.config.slew_indices, 0..) |slew, si| {
            for (self.config.load_indices, 0..) |load, li| {
                const pt = try self.measureSinglePoint(input_pin, output_pin, slew, load);
                arc.cell_rise.set(si, li, pt.tpd_rise_ns);
                arc.cell_fall.set(si, li, pt.tpd_fall_ns);
                arc.rise_transition.set(si, li, pt.t_rise_ns);
                arc.fall_transition.set(si, li, pt.t_fall_ns);
                pwr.rise_power.set(si, li, pt.rise_pj);
                pwr.fall_power.set(si, li, pt.fall_pj);
            }
        }

        return .{ .arc = arc, .power = pwr };
    }

    fn measureInputCap(self: *SimContext, pin_name: []const u8) !f64 {
        // Use AC analysis: apply AC source, measure input impedance at low freq
        var deck = std.ArrayList(u8).init(self.allocator);
        defer deck.deinit();
        const w = deck.writer();

        try self.writeDeckHeader(w);

        const vdd = self.config.nom_voltage;

        // AC source on pin
        try w.print("vac {s} 0 dc {d:.3} ac 1\n", .{ pin_name, vdd / 2.0 });

        // Bias other inputs
        for (self.ports) |port| {
            if (port.role == .signal_in and !std.mem.eql(u8, port.name, pin_name)) {
                try w.print("v_bias_{s} {s} 0 dc {d:.3}\n", .{ port.name, port.name, vdd / 2.0 });
            }
        }

        // AC analysis at 1MHz - get impedance, extract C
        try w.writeAll(
            \\
            \\.control
            \\ac dec 1 1e6 1e6
            \\let zin = 1/abs(i(vac))
            \\let cin = 1/(6.2832e6 * imag(1/i(vac)))
            \\* Fallback: use gate oxide capacitance estimate
            \\echo "MEAS_CIN=$&cin"
            \\quit
            \\.endc
            \\.end
            \\
        );

        const output = try self.runNgspice(deck.items);
        defer self.allocator.free(output);

        const cin_f = parseNamedValue(output, "MEAS_CIN=") orelse 5.0e-15; // 5fF fallback
        return @abs(cin_f) * 1.0e12; // F -> pF
    }

    fn writeDeckHeader(self: *SimContext, w: anytype) !void {
        try w.writeAll("* Spout Liberty characterization testbench\n\n");

        if (self.config.model_lib_path.len > 0) {
            try w.print(".lib \"{s}\" {s}\n\n", .{ self.config.model_lib_path, self.config.model_corner });
        }

        try w.print("* Cell netlist\n{s}\n\n", .{self.spice_content});

        // Instantiate DUT
        try w.writeAll("* DUT\nxdut");
        for (self.ports) |port| {
            try w.print(" {s}", .{port.name});
        }
        try w.print(" {s}\n\n", .{self.cell_name});

        // Supply
        try w.print("vvdd {s} 0 dc {d:.3}\n", .{ self.config.vdd_net, self.config.nom_voltage });
        try w.print("vvss {s} 0 dc 0\n", .{self.config.vss_net});

        // Well-bias: nwell → VDD, pwell → VSS
        for (self.ports) |port| {
            if (port.role == .nwell) {
                try w.print("v_well_{s} {s} 0 dc {d:.3}\n", .{ port.name, port.name, self.config.nom_voltage });
            } else if (port.role == .pwell) {
                try w.print("v_well_{s} {s} 0 dc 0\n", .{ port.name, port.name });
            }
        }
        try w.writeAll("\n");
    }

    fn runNgspice(self: *SimContext, deck_content: []const u8) ![]const u8 {
        const deck_path = "/tmp/spout_liberty_deck.sp";
        {
            const f = std.fs.cwd().createFile(deck_path, .{}) catch
                return try self.allocator.dupe(u8, "");
            defer f.close();
            f.writeAll(deck_content) catch
                return try self.allocator.dupe(u8, "");
        }

        const result = std.process.Child.run(.{
            .allocator = self.allocator,
            .argv = &.{ "ngspice", "-b", deck_path },
            .max_output_bytes = 1024 * 1024,
        }) catch {
            return try self.allocator.dupe(u8, "");
        };
        defer self.allocator.free(result.stderr);

        return result.stdout;
    }
};

// ─── Output parsing ─────────────────────────────────────────────────────────

fn parseNamedValue(output: []const u8, key: []const u8) ?f64 {
    var pos: usize = 0;
    while (pos + key.len <= output.len) : (pos += 1) {
        if (std.mem.startsWith(u8, output[pos..], key)) {
            const val_start = pos + key.len;
            var val_end = val_start;
            while (val_end < output.len and
                output[val_end] != '\n' and
                output[val_end] != '\r' and
                output[val_end] != ' ' and
                output[val_end] != '"')
            {
                val_end += 1;
            }
            const val_str = std.mem.trim(u8, output[val_start..val_end], " \t\"");
            return std.fmt.parseFloat(f64, val_str) catch null;
        }
    }
    return null;
}

// ─── Tests ──────────────────────────────────────────────────────────────────

test "classifyPort" {
    try std.testing.expectEqual(PortRole.vdd, classifyPort("VDD"));
    try std.testing.expectEqual(PortRole.vdd, classifyPort("VPWR"));
    try std.testing.expectEqual(PortRole.vss, classifyPort("VSS"));
    try std.testing.expectEqual(PortRole.vss, classifyPort("GND"));
    try std.testing.expectEqual(PortRole.nwell, classifyPort("VPB"));
    try std.testing.expectEqual(PortRole.pwell, classifyPort("VNB"));
    try std.testing.expectEqual(PortRole.signal_out, classifyPort("VOUT"));
    try std.testing.expectEqual(PortRole.signal_out, classifyPort("OUT"));
    try std.testing.expectEqual(PortRole.signal_in, classifyPort("INP"));
    try std.testing.expectEqual(PortRole.signal_in, classifyPort("CLK"));
}

test "parseSubcktPorts" {
    const spice =
        \\.subckt my_inv INP OUT VDD VSS
        \\M0 OUT INP VDD VDD sky130_fd_pr__pfet_01v8 w=1u l=0.15u
        \\M1 OUT INP VSS VSS sky130_fd_pr__nfet_01v8 w=0.5u l=0.15u
        \\.ends my_inv
    ;
    const ports = try parseSubcktPorts(std.testing.allocator, spice, "my_inv");
    defer std.testing.allocator.free(ports);

    try std.testing.expectEqual(@as(usize, 4), ports.len);
    try std.testing.expectEqualStrings("INP", ports[0].name);
    try std.testing.expectEqual(PortRole.signal_in, ports[0].role);
    try std.testing.expectEqualStrings("OUT", ports[1].name);
    try std.testing.expectEqual(PortRole.signal_out, ports[1].role);
    try std.testing.expectEqualStrings("VDD", ports[2].name);
    try std.testing.expectEqual(PortRole.vdd, ports[2].role);
}

test "parseNamedValue" {
    const output = "stuff\nMEAS_LEAK=1.234e-09\nmore\n";
    const val = parseNamedValue(output, "MEAS_LEAK=");
    try std.testing.expect(val != null);
    try std.testing.expectApproxEqRel(@as(f64, 1.234e-09), val.?, 1e-6);
}

test "parseNamedValue missing" {
    try std.testing.expect(parseNamedValue("no match\n", "MEAS_X=") == null);
}

test "containsIgnoreCase" {
    try std.testing.expect(containsIgnoreCase("VOUT", "OUT"));
    try std.testing.expect(containsIgnoreCase("output", "OUT"));
    try std.testing.expect(!containsIgnoreCase("VIN", "OUT"));
    try std.testing.expect(!containsIgnoreCase("A", "OUT"));
}
