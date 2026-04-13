const std = @import("std");
const testing = std.testing;

const core_types = @import("../core/types.zig");
const DeviceType = core_types.DeviceType;
const TerminalType = core_types.TerminalType;
const NetIdx = core_types.NetIdx;

const tokenizer_mod = @import("tokenizer.zig");
const Tokenizer = tokenizer_mod.Tokenizer;
const Token = tokenizer_mod.Token;
const parseSiValue = tokenizer_mod.parseSiValue;
const isPowerNet = tokenizer_mod.isPowerNet;
const PinEdge = tokenizer_mod.PinEdge;
const ParseError = tokenizer_mod.ParseError;

// ─── OTA (5-transistor) ─────────────────────────────────────────────────────

const ota_netlist =
    \\.subckt ota VDD VSS INP INN OUT
    \\M1 tail INP diff_a VSS nmos w=2u l=0.13u m=1
    \\M2 tail INN diff_b VSS nmos w=2u l=0.13u m=1
    \\M3 VDD VDD diff_a VDD pmos w=4u l=0.13u m=1
    \\M4 VDD VDD diff_b VDD pmos w=4u l=0.13u m=1
    \\M5 tail bias_n VSS VSS nmos w=4u l=0.13u m=2
    \\.ends ota
;

test "OTA - 5 devices parsed" {
    var tok = Tokenizer.init(testing.allocator);
    defer tok.deinit();
    var result = try tok.parse(ota_netlist);
    defer result.deinit();
    try testing.expectEqual(@as(usize, 5), result.devices.len);
}

test "OTA - correct device types (3 nmos, 2 pmos)" {
    var tok = Tokenizer.init(testing.allocator);
    defer tok.deinit();
    var result = try tok.parse(ota_netlist);
    defer result.deinit();

    var nmos_count: usize = 0;
    var pmos_count: usize = 0;
    for (result.devices) |dev| {
        switch (dev.device_type) {
            .nmos => nmos_count += 1,
            .pmos => pmos_count += 1,
            else => {},
        }
    }
    try testing.expectEqual(@as(usize, 3), nmos_count);
    try testing.expectEqual(@as(usize, 2), pmos_count);
}

test "OTA - VDD and VSS are power nets" {
    var tok = Tokenizer.init(testing.allocator);
    defer tok.deinit();
    var result = try tok.parse(ota_netlist);
    defer result.deinit();

    const vdd_idx = result.getNetIdx("VDD").?;
    try testing.expect(result.nets[vdd_idx.toInt()].is_power);
    const vss_idx = result.getNetIdx("VSS").?;
    try testing.expect(result.nets[vss_idx.toInt()].is_power);
    const inp_idx = result.getNetIdx("INP").?;
    try testing.expect(!result.nets[inp_idx.toInt()].is_power);
    const diff_a_idx = result.getNetIdx("diff_a").?;
    try testing.expect(!result.nets[diff_a_idx.toInt()].is_power);
}

test "OTA - pin edges sorted by terminal type within each device" {
    var tok = Tokenizer.init(testing.allocator);
    defer tok.deinit();
    var result = try tok.parse(ota_netlist);
    defer result.deinit();

    for (0..5) |dev_i| {
        const base = dev_i * 4;
        const pin0 = result.pins[base];
        const pin1 = result.pins[base + 1];
        const pin2 = result.pins[base + 2];
        const pin3 = result.pins[base + 3];
        try testing.expectEqual(@as(u32, @intCast(dev_i)), pin0.device.toInt());
        try testing.expectEqual(@as(u32, @intCast(dev_i)), pin1.device.toInt());
        try testing.expectEqual(@as(u32, @intCast(dev_i)), pin2.device.toInt());
        try testing.expectEqual(@as(u32, @intCast(dev_i)), pin3.device.toInt());
        try testing.expect(@intFromEnum(pin0.terminal) <= @intFromEnum(pin1.terminal));
        try testing.expect(@intFromEnum(pin1.terminal) <= @intFromEnum(pin2.terminal));
        try testing.expect(@intFromEnum(pin2.terminal) <= @intFromEnum(pin3.terminal));
    }
}

test "OTA - W/L values parsed correctly" {
    var tok = Tokenizer.init(testing.allocator);
    defer tok.deinit();
    var result = try tok.parse(ota_netlist);
    defer result.deinit();

    try testing.expectApproxEqAbs(@as(f32, 2e-6), result.devices[0].params.w, 1e-12);
    try testing.expectApproxEqAbs(@as(f32, 0.13e-6), result.devices[0].params.l, 1e-12);
    try testing.expectApproxEqAbs(@as(f32, 2e-6), result.devices[1].params.w, 1e-12);
    try testing.expectApproxEqAbs(@as(f32, 0.13e-6), result.devices[1].params.l, 1e-12);
    try testing.expectApproxEqAbs(@as(f32, 4e-6), result.devices[2].params.w, 1e-12);
    try testing.expectApproxEqAbs(@as(f32, 0.13e-6), result.devices[2].params.l, 1e-12);
    try testing.expectApproxEqAbs(@as(f32, 4e-6), result.devices[3].params.w, 1e-12);
    try testing.expectApproxEqAbs(@as(f32, 0.13e-6), result.devices[3].params.l, 1e-12);
    try testing.expectApproxEqAbs(@as(f32, 4e-6), result.devices[4].params.w, 1e-12);
    try testing.expectApproxEqAbs(@as(f32, 0.13e-6), result.devices[4].params.l, 1e-12);
    try testing.expectEqual(@as(u16, 2), result.devices[4].params.mult);
}

test "OTA - multiplier (m parameter) defaults to 1" {
    var tok = Tokenizer.init(testing.allocator);
    defer tok.deinit();
    var result = try tok.parse(ota_netlist);
    defer result.deinit();

    for (0..4) |i| try testing.expectEqual(@as(u16, 1), result.devices[i].params.mult);
    try testing.expectEqual(@as(u16, 2), result.devices[4].params.mult);
}

test "OTA - subcircuit ports detected" {
    var tok = Tokenizer.init(testing.allocator);
    defer tok.deinit();
    var result = try tok.parse(ota_netlist);
    defer result.deinit();

    try testing.expectEqual(@as(usize, 1), result.subcircuits.len);
    try testing.expectEqualStrings("ota", result.subcircuits[0].name);
    try testing.expectEqual(@as(usize, 5), result.subcircuits[0].ports.len);
    try testing.expectEqualStrings("VDD", result.subcircuits[0].ports[0]);
    try testing.expectEqualStrings("VSS", result.subcircuits[0].ports[1]);
    try testing.expectEqualStrings("INP", result.subcircuits[0].ports[2]);
    try testing.expectEqualStrings("INN", result.subcircuits[0].ports[3]);
    try testing.expectEqualStrings("OUT", result.subcircuits[0].ports[4]);
}

test "OTA - total pin count = 5 devices x 4 pins = 20" {
    var tok = Tokenizer.init(testing.allocator);
    defer tok.deinit();
    var result = try tok.parse(ota_netlist);
    defer result.deinit();
    try testing.expectEqual(@as(usize, 20), result.pins.len);
}

test "OTA - net fanout computed correctly" {
    var tok = Tokenizer.init(testing.allocator);
    defer tok.deinit();
    var result = try tok.parse(ota_netlist);
    defer result.deinit();

    const vdd_idx = result.getNetIdx("VDD").?;
    try testing.expectEqual(@as(u32, 6), result.nets[vdd_idx.toInt()].fanout);
    const vss_idx = result.getNetIdx("VSS").?;
    try testing.expectEqual(@as(u32, 4), result.nets[vss_idx.toInt()].fanout);
    const tail_idx = result.getNetIdx("tail").?;
    try testing.expectEqual(@as(u32, 3), result.nets[tail_idx.toInt()].fanout);
    const diff_a_idx = result.getNetIdx("diff_a").?;
    try testing.expectEqual(@as(u32, 2), result.nets[diff_a_idx.toInt()].fanout);
}

// ─── Current Mirror ──────────────────────────────────────────────────────────

const mirror_netlist =
    \\M1 out gate gate VSS nmos w=1u l=0.5u
    \\M2 mirror gate VSS VSS nmos w=1u l=0.5u
;

test "Mirror - 2 devices parsed" {
    var tok = Tokenizer.init(testing.allocator);
    defer tok.deinit();
    var result = try tok.parse(mirror_netlist);
    defer result.deinit();
    try testing.expectEqual(@as(usize, 2), result.devices.len);
}

test "Mirror - both devices are nmos" {
    var tok = Tokenizer.init(testing.allocator);
    defer tok.deinit();
    var result = try tok.parse(mirror_netlist);
    defer result.deinit();
    try testing.expectEqual(DeviceType.nmos, result.devices[0].device_type);
    try testing.expectEqual(DeviceType.nmos, result.devices[1].device_type);
}

test "Mirror - 2 devices sharing gate net" {
    var tok = Tokenizer.init(testing.allocator);
    defer tok.deinit();
    var result = try tok.parse(mirror_netlist);
    defer result.deinit();

    const gate_idx = result.getNetIdx("gate").?;
    const gate_fanout = result.nets[gate_idx.toInt()].fanout;
    try testing.expectEqual(@as(u32, 3), gate_fanout);
    const gate_pins = result.adj.pinsOnNet(gate_idx);
    try testing.expectEqual(@as(usize, 3), gate_pins.len);
}

test "Mirror - W/L values" {
    var tok = Tokenizer.init(testing.allocator);
    defer tok.deinit();
    var result = try tok.parse(mirror_netlist);
    defer result.deinit();

    for (result.devices) |dev| {
        try testing.expectApproxEqAbs(@as(f32, 1e-6), dev.params.w, 1e-12);
        try testing.expectApproxEqAbs(@as(f32, 0.5e-6), dev.params.l, 1e-12);
    }
}

test "Mirror - VSS is power net" {
    var tok = Tokenizer.init(testing.allocator);
    defer tok.deinit();
    var result = try tok.parse(mirror_netlist);
    defer result.deinit();
    const vss_idx = result.getNetIdx("VSS").?;
    try testing.expect(result.nets[vss_idx.toInt()].is_power);
}

test "Mirror - default multiplier is 1" {
    var tok = Tokenizer.init(testing.allocator);
    defer tok.deinit();
    var result = try tok.parse(mirror_netlist);
    defer result.deinit();
    for (result.devices) |dev| try testing.expectEqual(@as(u16, 1), dev.params.mult);
}

// ─── Tokenizer-level tests ──────────────────────────────────────────────────

test "Tokenizer - SI suffix parsing comprehensive" {
    try testing.expectApproxEqAbs(@as(f64, 1e-15), parseSiValue("1f").?, 1e-27);
    try testing.expectApproxEqAbs(@as(f64, 3.3e-12), parseSiValue("3.3p").?, 1e-24);
    try testing.expectApproxEqAbs(@as(f64, 100e-9), parseSiValue("100n").?, 1e-18);
    try testing.expectApproxEqAbs(@as(f64, 2e-6), parseSiValue("2u").?, 1e-18);
    try testing.expectApproxEqAbs(@as(f64, 2.2e-3), parseSiValue("2.2m").?, 1e-15);
    try testing.expectApproxEqAbs(@as(f64, 10e3), parseSiValue("10k").?, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 1e6), parseSiValue("1meg").?, 1e-6);
    try testing.expectApproxEqAbs(@as(f64, 42.0), parseSiValue("42").?, 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 1.5e-6), parseSiValue("1.5e-6").?, 1e-18);
    try testing.expectEqual(@as(?f64, null), parseSiValue("abc"));
    try testing.expectEqual(@as(?f64, null), parseSiValue(""));
}

test "Tokenizer - continuation lines merge correctly" {
    var tok = Tokenizer.init(testing.allocator);
    defer tok.deinit();

    const source =
        \\M1 drain gate source body
        \\+ nmos w=2u l=0.13u
        \\+ m=4
    ;
    const lines = try tok.tokenize(source);
    try testing.expectEqual(@as(usize, 1), lines.len);
    try testing.expectEqual(Token.Tag.mosfet, lines[0].tag);
    try testing.expectEqual(@as(usize, 9), lines[0].tokens.len);
    try testing.expectEqual(@as(usize, 3), lines[0].params.len);
}

test "Tokenizer - comments are skipped" {
    var tok = Tokenizer.init(testing.allocator);
    defer tok.deinit();

    const source =
        \\* This is a comment
        \\M1 a b c d nmos
        \\* Another comment
    ;
    const lines = try tok.tokenize(source);
    var mosfet_count: usize = 0;
    var comment_count: usize = 0;
    for (lines) |line| {
        if (line.tag == .mosfet) mosfet_count += 1;
        if (line.tag == .comment) comment_count += 1;
    }
    try testing.expectEqual(@as(usize, 1), mosfet_count);
    try testing.expectEqual(@as(usize, 2), comment_count);
}

// ─── Edge cases ──────────────────────────────────────────────────────────────

test "Parser - empty input" {
    var tok = Tokenizer.init(testing.allocator);
    defer tok.deinit();
    var result = try tok.parse("");
    defer result.deinit();
    try testing.expectEqual(@as(usize, 0), result.devices.len);
    try testing.expectEqual(@as(usize, 0), result.nets.len);
    try testing.expectEqual(@as(usize, 0), result.pins.len);
}

test "Parser - comments only" {
    var tok = Tokenizer.init(testing.allocator);
    defer tok.deinit();
    var result = try tok.parse("* Comment 1\n* Comment 2\n* Comment 3");
    defer result.deinit();
    try testing.expectEqual(@as(usize, 0), result.devices.len);
}

test "Parser - mixed devices" {
    var tok = Tokenizer.init(testing.allocator);
    defer tok.deinit();
    var result = try tok.parse(
        \\M1 d g s b nmos w=1u l=0.5u
        \\R1 n1 n2 10k
        \\C1 n3 n4 1p
    );
    defer result.deinit();
    try testing.expectEqual(@as(usize, 3), result.devices.len);
    try testing.expectEqual(DeviceType.nmos, result.devices[0].device_type);
    try testing.expectEqual(DeviceType.res, result.devices[1].device_type);
    try testing.expectEqual(DeviceType.cap, result.devices[2].device_type);
    try testing.expectApproxEqAbs(@as(f32, 10e3), result.devices[1].params.value, 1.0);
    try testing.expectApproxEqAbs(@as(f32, 1e-12), result.devices[2].params.value, 1e-18);
}

test "Parser - PMOS device type" {
    var tok = Tokenizer.init(testing.allocator);
    defer tok.deinit();
    var result = try tok.parse("M1 VDD VDD out VDD pmos w=10u l=1u");
    defer result.deinit();
    try testing.expectEqual(DeviceType.pmos, result.devices[0].device_type);
}

test "Parser - case insensitive device type" {
    var tok = Tokenizer.init(testing.allocator);
    defer tok.deinit();
    var result = try tok.parse("M1 d g s b NMOS w=1u l=0.5u\nM2 d g s b PMOS w=1u l=0.5u");
    defer result.deinit();
    try testing.expectEqual(DeviceType.nmos, result.devices[0].device_type);
    try testing.expectEqual(DeviceType.pmos, result.devices[1].device_type);
}

test "Parser - net interning deduplicates" {
    var tok = Tokenizer.init(testing.allocator);
    defer tok.deinit();
    var result = try tok.parse(
        \\M1 shared_net g1 s1 b1 nmos w=1u l=1u
        \\M2 shared_net g2 s2 b2 nmos w=1u l=1u
    );
    defer result.deinit();

    var count: usize = 0;
    for (result.nets) |net| {
        if (std.mem.eql(u8, net.name, "shared_net")) count += 1;
    }
    try testing.expectEqual(@as(usize, 1), count);
    const idx = result.getNetIdx("shared_net").?;
    try testing.expectEqual(@as(u32, 2), result.nets[idx.toInt()].fanout);
}

test "Parser - FlatAdjList CSR structure valid" {
    var tok = Tokenizer.init(testing.allocator);
    defer tok.deinit();
    var result = try tok.parse(ota_netlist);
    defer result.deinit();

    const num_nets = result.adj.num_nets;
    try testing.expectEqual(@as(usize, num_nets + 1), result.adj.row_ptr.len);
    var i: u32 = 0;
    while (i < num_nets) : (i += 1) {
        try testing.expect(result.adj.row_ptr[i] <= result.adj.row_ptr[i + 1]);
    }
    try testing.expectEqual(@as(u32, @intCast(result.pins.len)), result.adj.row_ptr[num_nets]);
    try testing.expectEqual(result.pins.len, result.adj.col_idx.len);
}

test "Parser - resistor value with various SI suffixes" {
    var tok = Tokenizer.init(testing.allocator);
    defer tok.deinit();
    var result = try tok.parse("R1 a b 100n\nR2 c d 3.3p\nR3 e f 10k\nR4 g h 1meg");
    defer result.deinit();
    try testing.expectEqual(@as(usize, 4), result.devices.len);
    try testing.expectApproxEqAbs(@as(f32, 100e-9), result.devices[0].params.value, 1e-15);
    try testing.expectApproxEqAbs(@as(f32, 3.3e-12), result.devices[1].params.value, 1e-18);
    try testing.expectApproxEqAbs(@as(f32, 10e3), result.devices[2].params.value, 1.0);
    try testing.expectApproxEqAbs(@as(f32, 1e6), result.devices[3].params.value, 100.0);
}

test "Parser - capacitor value with SI suffix" {
    var tok = Tokenizer.init(testing.allocator);
    defer tok.deinit();
    var result = try tok.parse("C1 a b 100n\nC2 c d 3.3p");
    defer result.deinit();
    try testing.expectEqual(DeviceType.cap, result.devices[0].device_type);
    try testing.expectEqual(DeviceType.cap, result.devices[1].device_type);
    try testing.expectApproxEqAbs(@as(f32, 100e-9), result.devices[0].params.value, 1e-15);
    try testing.expectApproxEqAbs(@as(f32, 3.3e-12), result.devices[1].params.value, 1e-18);
}

test "Parser - circuit with continuation lines" {
    var tok = Tokenizer.init(testing.allocator);
    defer tok.deinit();
    var result = try tok.parse(
        \\M1 drain gate source body
        \\+ nmos w=2u
        \\+ l=0.13u m=2
    );
    defer result.deinit();
    try testing.expectEqual(DeviceType.nmos, result.devices[0].device_type);
    try testing.expectApproxEqAbs(@as(f32, 2e-6), result.devices[0].params.w, 1e-12);
    try testing.expectApproxEqAbs(@as(f32, 0.13e-6), result.devices[0].params.l, 1e-12);
    try testing.expectEqual(@as(u16, 2), result.devices[0].params.mult);
}

test "Parser - PMOS vs NMOS case insensitivity" {
    var tok = Tokenizer.init(testing.allocator);
    defer tok.deinit();
    var result = try tok.parse(
        \\M1 d g s b NMOS w=1u l=1u
        \\M2 d g s b Nmos w=1u l=1u
        \\M3 d g s b nmos w=1u l=1u
        \\M4 d g s b PMOS w=1u l=1u
        \\M5 d g s b Pmos w=1u l=1u
        \\M6 d g s b pmos w=1u l=1u
    );
    defer result.deinit();
    try testing.expectEqual(@as(usize, 6), result.devices.len);
    for (0..3) |i| try testing.expectEqual(DeviceType.nmos, result.devices[i].device_type);
    for (3..6) |i| try testing.expectEqual(DeviceType.pmos, result.devices[i].device_type);
}

test "Parser - netlist with .subckt/.ends wrapping" {
    var tok = Tokenizer.init(testing.allocator);
    defer tok.deinit();
    var result = try tok.parse(
        \\.subckt inverter VDD VSS IN OUT
        \\M1 OUT IN VDD VDD pmos w=4u l=0.13u
        \\M2 OUT IN VSS VSS nmos w=2u l=0.13u
        \\.ends inverter
    );
    defer result.deinit();
    try testing.expectEqual(@as(usize, 2), result.devices.len);
    try testing.expectEqual(@as(usize, 1), result.subcircuits.len);
    try testing.expectEqualStrings("inverter", result.subcircuits[0].name);
    try testing.expectEqual(@as(usize, 4), result.subcircuits[0].ports.len);
    try testing.expectEqual(DeviceType.pmos, result.devices[0].device_type);
    try testing.expectEqual(DeviceType.nmos, result.devices[1].device_type);
}

test "Parser - pin count = 4*mosfets + 2*resistors + 2*capacitors" {
    var tok = Tokenizer.init(testing.allocator);
    defer tok.deinit();
    var result = try tok.parse(
        \\M1 d1 g1 s1 b1 nmos w=1u l=1u
        \\M2 d2 g2 s2 b2 pmos w=1u l=1u
        \\R1 a b 10k
        \\C1 c d 1p
    );
    defer result.deinit();
    try testing.expectEqual(@as(usize, 12), result.pins.len);
}

test "Parser - empty netlist produces 0 devices" {
    var tok = Tokenizer.init(testing.allocator);
    defer tok.deinit();
    var result = try tok.parse("");
    defer result.deinit();
    try testing.expectEqual(@as(usize, 0), result.devices.len);
    try testing.expectEqual(@as(usize, 0), result.pins.len);
    try testing.expectEqual(@as(usize, 0), result.nets.len);
}

test "Parser - comment-only file produces 0 devices" {
    var tok = Tokenizer.init(testing.allocator);
    defer tok.deinit();
    var result = try tok.parse("* This is a comment file\n* It has no devices\n* Only comments");
    defer result.deinit();
    try testing.expectEqual(@as(usize, 0), result.devices.len);
    try testing.expectEqual(@as(usize, 0), result.pins.len);
}

test "Parser - net name interning deduplication same name same NetIdx" {
    var tok = Tokenizer.init(testing.allocator);
    defer tok.deinit();
    var result = try tok.parse(
        \\M1 shared g1 s1 b1 nmos w=1u l=1u
        \\M2 shared g2 s2 b2 nmos w=1u l=1u
        \\M3 shared g3 s3 b3 nmos w=1u l=1u
    );
    defer result.deinit();

    const idx1 = result.getNetIdx("shared");
    try testing.expect(idx1 != null);
    var count: usize = 0;
    for (result.nets) |net| {
        if (std.mem.eql(u8, net.name, "shared")) count += 1;
    }
    try testing.expectEqual(@as(usize, 1), count);
    try testing.expectEqual(@as(u32, 3), result.nets[idx1.?.toInt()].fanout);
}

test "Parser - inductor parsing" {
    var tok = Tokenizer.init(testing.allocator);
    defer tok.deinit();
    var result = try tok.parse("L1 in out 1n");
    defer result.deinit();
    try testing.expectEqual(@as(usize, 1), result.devices.len);
    try testing.expectEqual(core_types.DeviceType.ind, result.devices[0].device_type);
    try testing.expectApproxEqAbs(@as(f32, 1e-9), result.devices[0].params.value, 1e-15);
    try testing.expectEqual(@as(usize, 2), result.pins.len);
}

test "Parser - nch/pch aliases" {
    var tok = Tokenizer.init(testing.allocator);
    defer tok.deinit();
    var result = try tok.parse("M1 d g s b nch w=1u l=1u\nM2 d g s b pch w=1u l=1u");
    defer result.deinit();
    try testing.expectEqual(DeviceType.nmos, result.devices[0].device_type);
    try testing.expectEqual(DeviceType.pmos, result.devices[1].device_type);
}

test "Parser - subcircuit instantiation (X line)" {
    var tok = Tokenizer.init(testing.allocator);
    defer tok.deinit();
    var result = try tok.parse(
        \\.subckt inv VDD VSS IN OUT
        \\M1 OUT IN VDD VDD pmos w=4u l=0.13u
        \\M2 OUT IN VSS VSS nmos w=2u l=0.13u
        \\.ends inv
        \\.subckt buf VDD VSS IN OUT
        \\xi0 VDD VSS IN net1 inv
        \\xi1 VDD VSS net1 OUT inv
        \\.ends buf
    );
    defer result.deinit();
    try testing.expectEqual(@as(usize, 4), result.devices.len);
    try testing.expectEqual(DeviceType.pmos, result.devices[0].device_type);
    try testing.expectEqual(DeviceType.nmos, result.devices[1].device_type);
    try testing.expectEqual(DeviceType.subckt, result.devices[2].device_type);
    try testing.expectEqual(DeviceType.subckt, result.devices[3].device_type);
    try testing.expectEqual(@as(usize, 2), result.subcircuits.len);
    try testing.expectEqualStrings("inv", result.subcircuits[0].name);
    try testing.expectEqualStrings("buf", result.subcircuits[1].name);
}

test "Parser - X instance with multiplier m=N" {
    var tok = Tokenizer.init(testing.allocator);
    defer tok.deinit();
    var result = try tok.parse("xmn29 net093 cmfb_p1 vssa vssa nlvt_s_pcell_0 m=4");
    defer result.deinit();
    try testing.expectEqual(@as(usize, 1), result.devices.len);
    try testing.expectEqual(DeviceType.subckt, result.devices[0].device_type);
    try testing.expectEqual(@as(u16, 4), result.devices[0].params.mult);
}

test "Parser - .model line skipped gracefully" {
    var tok = Tokenizer.init(testing.allocator);
    defer tok.deinit();
    var result = try tok.parse(".model pulvt pmos l=1 w=1 nf=1 m=1\nM1 d g s b nmos w=1u l=1u");
    defer result.deinit();
    try testing.expectEqual(@as(usize, 1), result.devices.len);
    try testing.expectEqual(DeviceType.nmos, result.devices[0].device_type);
}

test "Parser - .param line skipped gracefully" {
    var tok = Tokenizer.init(testing.allocator);
    defer tok.deinit();
    var result = try tok.parse(".param m=1\nM1 d g s b nmos w=1u l=1u");
    defer result.deinit();
    try testing.expectEqual(@as(usize, 1), result.devices.len);
}

test "Parser - .global line skipped gracefully" {
    var tok = Tokenizer.init(testing.allocator);
    defer tok.deinit();
    var result = try tok.parse(".global VDD VSS\nM1 d g s b nmos w=1u l=1u");
    defer result.deinit();
    try testing.expectEqual(@as(usize, 1), result.devices.len);
}

test "Parser - .include and .lib skipped gracefully" {
    var tok = Tokenizer.init(testing.allocator);
    defer tok.deinit();
    var result = try tok.parse(
        \\.include "models/nmos.lib"
        \\.lib "models/pmos.lib" tt
        \\M1 d g s b nmos w=1u l=1u
    );
    defer result.deinit();
    try testing.expectEqual(@as(usize, 1), result.devices.len);
}

test "Parser - voltage/current sources skipped gracefully" {
    var tok = Tokenizer.init(testing.allocator);
    defer tok.deinit();
    var result = try tok.parse("V1 VDD 0 1.8\nI1 VDD net1 100u\nM1 d g s b nmos w=1u l=1u");
    defer result.deinit();
    try testing.expectEqual(@as(usize, 1), result.devices.len);
}

test "Parser - PDK MOSFET types: nlvt, plvt, pulvt" {
    var tok = Tokenizer.init(testing.allocator);
    defer tok.deinit();
    var result = try tok.parse(
        \\M1 d g s b nlvt w=180e-9 l=40e-9 m=1 nf=2
        \\M2 d g s b plvt w=360e-9 l=40e-9 m=1 nf=2
        \\M3 d g s b pulvt w=1.44e-6 l=40e-9 m=1 nf=4
    );
    defer result.deinit();
    try testing.expectEqual(@as(usize, 3), result.devices.len);
    try testing.expectEqual(DeviceType.nmos, result.devices[0].device_type);
    try testing.expectEqual(DeviceType.pmos, result.devices[1].device_type);
    try testing.expectEqual(DeviceType.pmos, result.devices[2].device_type);
}

test "Parser - PDK MOSFET types: lvtpfet, lvtnfet" {
    var tok = Tokenizer.init(testing.allocator);
    defer tok.deinit();
    var result = try tok.parse(
        \\MP2 net3 B net1 VDD lvtpfet m=1 l=14n nfin=4 nf=2
        \\MN1 net8 net8 net5 VSS lvtnfet m=1 l=14n nfin=6 nf=3
    );
    defer result.deinit();
    try testing.expectEqual(@as(usize, 2), result.devices.len);
    try testing.expectEqual(DeviceType.pmos, result.devices[0].device_type);
    try testing.expectEqual(DeviceType.nmos, result.devices[1].device_type);
    try testing.expectEqual(@as(u16, 2), result.devices[0].params.fingers);
    try testing.expectEqual(@as(u16, 3), result.devices[1].params.fingers);
}

test "Parser - nf (fingers) parameter parsed" {
    var tok = Tokenizer.init(testing.allocator);
    defer tok.deinit();
    var result = try tok.parse("M1 d g s b nmos w=180e-9 l=40e-9 m=1 nf=6");
    defer result.deinit();
    try testing.expectEqual(@as(u16, 6), result.devices[0].params.fingers);
}

test "Tokenizer - // comment lines" {
    var tok = Tokenizer.init(testing.allocator);
    defer tok.deinit();
    const lines = try tok.tokenize(
        \\// This is a C-style comment
        \\M1 d g s b nmos w=1u l=1u
        \\// Another comment
    );
    var mosfet_count: usize = 0;
    var comment_count: usize = 0;
    for (lines) |line| {
        if (line.tag == .mosfet) mosfet_count += 1;
        if (line.tag == .comment) comment_count += 1;
    }
    try testing.expectEqual(@as(usize, 1), mosfet_count);
    try testing.expectEqual(@as(usize, 2), comment_count);
}

test "Tokenizer - backslash continuation lines" {
    var tok = Tokenizer.init(testing.allocator);
    defer tok.deinit();
    const lines = try tok.tokenize(".param nfin=14 rres=2k \\\n    width_n=10 width_p=16");
    try testing.expectEqual(@as(usize, 1), lines.len);
    try testing.expectEqual(Token.Tag.dot_param, lines[0].tag);
}

test "Tokenizer - X instance line classified as subckt_inst" {
    var tok = Tokenizer.init(testing.allocator);
    defer tok.deinit();
    const lines = try tok.tokenize("xi0 VDD VSS IN net1 inv");
    try testing.expectEqual(@as(usize, 1), lines.len);
    try testing.expectEqual(Token.Tag.subckt_inst, lines[0].tag);
}

test "Tokenizer - leading whitespace on device lines" {
    var tok = Tokenizer.init(testing.allocator);
    defer tok.deinit();
    const lines = try tok.tokenize("    MP2 net3 B net1 VDD lvtpfet m=1 l=14n nfin=4 nf=2");
    try testing.expectEqual(@as(usize, 1), lines.len);
    try testing.expectEqual(Token.Tag.mosfet, lines[0].tag);
}

test "Parser - align_test_vga benchmark netlist" {
    var tok = Tokenizer.init(testing.allocator);
    defer tok.deinit();
    var result = try tok.parse(
        \\.model pulvt pmos l=1 w=1 nf=1 m=1
        \\
        \\.subckt nlvt_s_pcell_0 d g s b
        \\.param m=1
        \\mi1 d g inet1 b nlvt w=180e-9 l=40e-9 m=1 nf=2
        \\mi2 inet1 g inet2 b nlvt w=180e-9 l=40e-9 m=1 nf=2
        \\.ends nlvt_s_pcell_0
        \\
        \\.subckt test_vga_inv_als in in_b vcca vssa
        \\mqn1 in_b in vssa vssa nlvt w=180e-9 l=40e-9 m=1 nf=2
        \\mqp1 in_b in vcca vcca plvt w=180e-9 l=40e-9 m=1 nf=2
        \\.ends test_vga_inv_als
        \\
        \\.subckt test_vga_buf_als in out vcca vssa
        \\xi1 net7 out vcca vssa test_vga_inv_als
        \\xi0 in net7 vcca vssa test_vga_inv_als
        \\.ends test_vga_buf_als
        \\
        \\.subckt test_vga cmfb_p1 iref vcca vssa
        \\xmn29 net093 cmfb_p1 vssa vssa nlvt_s_pcell_0 m=1
        \\mmn16 voutp vcca net0103 vssa nlvt w=1.62e-6 l=40e-9 m=1 nf=6
        \\mmp10 net078 gain_ctrlb vcca vcca pulvt w=1.44e-6 l=40e-9 m=1 nf=4
        \\.ends test_vga
    );
    defer result.deinit();
    try testing.expectEqual(@as(usize, 9), result.devices.len);
    try testing.expectEqual(@as(usize, 4), result.subcircuits.len);
}

test "Parser - nested subcircuit definitions" {
    var tok = Tokenizer.init(testing.allocator);
    defer tok.deinit();
    var result = try tok.parse(
        \\.subckt top VDD VSS IN OUT
        \\.subckt inner VDD VSS A B
        \\M1 B A VDD VDD pmos w=4u l=0.13u
        \\M2 B A VSS VSS nmos w=2u l=0.13u
        \\.ends inner
        \\xi0 VDD VSS IN OUT inner
        \\.ends top
    );
    defer result.deinit();
    try testing.expectEqual(@as(usize, 3), result.devices.len);
    try testing.expectEqual(@as(usize, 2), result.subcircuits.len);
}

test "Parser - unrecognized dot commands skipped" {
    var tok = Tokenizer.init(testing.allocator);
    defer tok.deinit();
    var result = try tok.parse(
        \\.option post=1
        \\.options reltol=1e-6
        \\.temp 27
        \\.tran 1n 100n
        \\.dc V1 0 1.8 0.1
        \\.ac dec 10 1 1g
        \\.measure tran delay trig v(in) val=0.9 rise=1 targ v(out) val=0.9 fall=1
        \\M1 d g s b nmos w=1u l=1u
    );
    defer result.deinit();
    try testing.expectEqual(@as(usize, 1), result.devices.len);
}

test "Parser - PDK types: nmos_rvt, pmos_lvt" {
    var tok = Tokenizer.init(testing.allocator);
    defer tok.deinit();
    var result = try tok.parse(
        \\M1 d g s b nmos_rvt w=1u l=1u
        \\M2 d g s b pmos_lvt w=2u l=1u
        \\M3 d g s b nch_mac w=1u l=1u
        \\M4 d g s b pch_mac w=2u l=1u
    );
    defer result.deinit();
    try testing.expectEqual(@as(usize, 4), result.devices.len);
    try testing.expectEqual(DeviceType.nmos, result.devices[0].device_type);
    try testing.expectEqual(DeviceType.pmos, result.devices[1].device_type);
    try testing.expectEqual(DeviceType.nmos, result.devices[2].device_type);
    try testing.expectEqual(DeviceType.pmos, result.devices[3].device_type);
}

test "Parser - X instance with params (key=value after subckt name)" {
    var tok = Tokenizer.init(testing.allocator);
    defer tok.deinit();
    var result = try tok.parse("xI1 VDD VSS VBIAS o1 o2 three_terminal_inv _ar0=4 _ar1=1 _ar2=2 _ar3=6");
    defer result.deinit();
    try testing.expectEqual(@as(usize, 1), result.devices.len);
    try testing.expectEqual(DeviceType.subckt, result.devices[0].device_type);
    try testing.expectEqual(@as(usize, 5), result.pins.len);
}

test "Parser - inline comment with $" {
    var tok = Tokenizer.init(testing.allocator);
    defer tok.deinit();
    var result = try tok.parse("M1 d g s b nmos w=1u l=1u $ this is a comment");
    defer result.deinit();
    try testing.expectEqual(@as(usize, 1), result.devices.len);
    try testing.expectEqual(DeviceType.nmos, result.devices[0].device_type);
}

test "Parser - bus notation in node names" {
    var tok = Tokenizer.init(testing.allocator);
    defer tok.deinit();
    var result = try tok.parse(
        \\M1 out[0] in[0] VDD VDD pmos w=1u l=1u
        \\M2 out[1] in[1] VSS VSS nmos w=1u l=1u
    );
    defer result.deinit();
    try testing.expectEqual(@as(usize, 2), result.devices.len);
    try testing.expect(result.getNetIdx("out[0]") != null);
    try testing.expect(result.getNetIdx("in[1]") != null);
}

test "Parser - angle bracket bus notation" {
    var tok = Tokenizer.init(testing.allocator);
    defer tok.deinit();
    var result = try tok.parse("M1 o<1> o<2> VDD VDD pmos w=1u l=1u");
    defer result.deinit();
    try testing.expectEqual(@as(usize, 1), result.devices.len);
    try testing.expect(result.getNetIdx("o<1>") != null);
}

// ─── Physical resistor/capacitor model resolution ────────────────────────────

test "Parser - SKY130 poly resistor model" {
    var tok = Tokenizer.init(testing.allocator);
    defer tok.deinit();
    var result = try tok.parse("R1 a b sky130_fd_pr__res_high_po_0p35 w=350n l=2u");
    defer result.deinit();
    try testing.expectEqual(DeviceType.res_poly, result.devices[0].device_type);
    try testing.expectApproxEqAbs(@as(f32, 350e-9), result.devices[0].params.w, 1e-15);
    try testing.expectApproxEqAbs(@as(f32, 2e-6),   result.devices[0].params.l, 1e-12);
}

test "Parser - SKY130 p-well iso resistor model" {
    var tok = Tokenizer.init(testing.allocator);
    defer tok.deinit();
    var result = try tok.parse("R1 a b sky130_fd_pr__res_iso_pw w=2u l=20u");
    defer result.deinit();
    try testing.expectEqual(DeviceType.res_well_p, result.devices[0].device_type);
}

test "Parser - SKY130 n-diff and p-diff resistors" {
    var tok = Tokenizer.init(testing.allocator);
    defer tok.deinit();
    var result = try tok.parse(
        \\R1 a b sky130_fd_pr__res_generic_nd w=1u l=5u
        \\R2 a b sky130_fd_pr__res_generic_pd w=1u l=5u
    );
    defer result.deinit();
    try testing.expectEqual(DeviceType.res_diff_n, result.devices[0].device_type);
    try testing.expectEqual(DeviceType.res_diff_p, result.devices[1].device_type);
}

test "Parser - SKY130 MIM capacitor model" {
    var tok = Tokenizer.init(testing.allocator);
    defer tok.deinit();
    var result = try tok.parse("C1 a b sky130_fd_pr__cap_mim_m3_1 w=5u l=5u");
    defer result.deinit();
    try testing.expectEqual(DeviceType.cap_mim, result.devices[0].device_type);
    try testing.expectApproxEqAbs(@as(f32, 5e-6), result.devices[0].params.w, 1e-12);
    try testing.expectApproxEqAbs(@as(f32, 5e-6), result.devices[0].params.l, 1e-12);
}

test "Parser - GF180MCU resistor models" {
    var tok = Tokenizer.init(testing.allocator);
    defer tok.deinit();
    var result = try tok.parse(
        \\R1 a b nplus_u  w=1u l=5u
        \\R2 a b pplus_u  w=1u l=5u
        \\R3 a b ppolyf_u w=1u l=10u
        \\R4 a b nwell    w=4u l=50u
        \\R5 a b rm1      w=2u l=10u
    );
    defer result.deinit();
    try testing.expectEqual(DeviceType.res_diff_n, result.devices[0].device_type);
    try testing.expectEqual(DeviceType.res_diff_p, result.devices[1].device_type);
    try testing.expectEqual(DeviceType.res_poly,   result.devices[2].device_type);
    try testing.expectEqual(DeviceType.res_well_n, result.devices[3].device_type);
    try testing.expectEqual(DeviceType.res_metal,  result.devices[4].device_type);
}

test "Parser - GF180MCU MIM and gate capacitors" {
    var tok = Tokenizer.init(testing.allocator);
    defer tok.deinit();
    var result = try tok.parse(
        \\C1 a b mimcap   w=10u l=10u
        \\C2 a b cap_nmos w=2u  l=0.5u
        \\C3 a b cap_pmos w=2u  l=0.5u
    );
    defer result.deinit();
    try testing.expectEqual(DeviceType.cap_mim,  result.devices[0].device_type);
    try testing.expectEqual(DeviceType.cap_gate, result.devices[1].device_type);
    try testing.expectEqual(DeviceType.cap_gate, result.devices[2].device_type);
}

test "Parser - IHP SG13G2 resistor models" {
    var tok = Tokenizer.init(testing.allocator);
    defer tok.deinit();
    var result = try tok.parse(
        \\R1 a b rsil  w=1u l=5u
        \\R2 a b rhigh w=1u l=10u
        \\R3 a b rppd  w=1u l=3u
        \\R4 a b rnpd  w=1u l=3u
    );
    defer result.deinit();
    try testing.expectEqual(DeviceType.res_poly,   result.devices[0].device_type);
    try testing.expectEqual(DeviceType.res_poly,   result.devices[1].device_type);
    try testing.expectEqual(DeviceType.res_diff_p, result.devices[2].device_type);
    try testing.expectEqual(DeviceType.res_diff_n, result.devices[3].device_type);
}

test "Parser - IHP SG13G2 MIM capacitor" {
    var tok = Tokenizer.init(testing.allocator);
    defer tok.deinit();
    var result = try tok.parse("C1 a b cmim w=10u l=10u");
    defer result.deinit();
    try testing.expectEqual(DeviceType.cap_mim, result.devices[0].device_type);
}

test "Parser - generic R/C without model stays generic" {
    var tok = Tokenizer.init(testing.allocator);
    defer tok.deinit();
    var result = try tok.parse("R1 a b 10k\nC1 a b 1p\nL1 a b 1n");
    defer result.deinit();
    try testing.expectEqual(DeviceType.res, result.devices[0].device_type);
    try testing.expectEqual(DeviceType.cap, result.devices[1].device_type);
    try testing.expectEqual(DeviceType.ind, result.devices[2].device_type);
}

test "Parser - resistor with m multiplier and w/l" {
    var tok = Tokenizer.init(testing.allocator);
    defer tok.deinit();
    var result = try tok.parse("R1 a b sky130_fd_pr__res_high_po_0p69 w=690n l=5u m=4");
    defer result.deinit();
    try testing.expectEqual(DeviceType.res_poly, result.devices[0].device_type);
    try testing.expectEqual(@as(u16, 4), result.devices[0].params.mult);
}

test "Parser - unknown model name falls back to heuristic (poly keyword)" {
    var tok = Tokenizer.init(testing.allocator);
    defer tok.deinit();
    var result = try tok.parse("R1 a b custom_poly_res w=1u l=5u");
    defer result.deinit();
    try testing.expectEqual(DeviceType.res_poly, result.devices[0].device_type);
}

test "Parser - unknown cap model falls back to heuristic (mim keyword)" {
    var tok = Tokenizer.init(testing.allocator);
    defer tok.deinit();
    var result = try tok.parse("C1 a b custom_mim_cap w=5u l=5u");
    defer result.deinit();
    try testing.expectEqual(DeviceType.cap_mim, result.devices[0].device_type);
}

// ─── Diode ───────────────────────────────────────────────────────────────────

test "Parser - diode basic" {
    var tok = Tokenizer.init(testing.allocator);
    defer tok.deinit();
    var result = try tok.parse("D1 anode cathode dname");
    defer result.deinit();
    try testing.expectEqual(@as(usize, 1), result.devices.len);
    try testing.expectEqual(DeviceType.diode, result.devices[0].device_type);
    try testing.expectEqual(@as(usize, 2), result.pins.len);
}

test "Parser - diode anode/cathode terminals" {
    var tok = Tokenizer.init(testing.allocator);
    defer tok.deinit();
    var result = try tok.parse("D1 net_a net_k dmodel");
    defer result.deinit();
    try testing.expect(result.getNetIdx("net_a") != null);
    try testing.expect(result.getNetIdx("net_k") != null);
    const pins = result.pins;
    // pins sorted by terminal type: anode(4) < cathode(5)
    try testing.expectEqual(TerminalType.anode, pins[0].terminal);
    try testing.expectEqual(TerminalType.cathode, pins[1].terminal);
}

test "Parser - diode with area and multiplier" {
    var tok = Tokenizer.init(testing.allocator);
    defer tok.deinit();
    var result = try tok.parse("D1 a k dmod area=2 m=4");
    defer result.deinit();
    try testing.expectEqual(@as(f32, 2.0), result.devices[0].params.value);
    try testing.expectEqual(@as(u16, 4), result.devices[0].params.mult);
}

test "Parser - diode with power nets (ESD clamp)" {
    var tok = Tokenizer.init(testing.allocator);
    defer tok.deinit();
    var result = try tok.parse("DESD_P VDD sig sky130_fd_pr__diode_pw2nd_05v5\nDESD_N sig VSS sky130_fd_pr__diode_pw2nd_05v5");
    defer result.deinit();
    try testing.expectEqual(@as(usize, 2), result.devices.len);
    try testing.expectEqual(DeviceType.diode, result.devices[0].device_type);
    try testing.expectEqual(DeviceType.diode, result.devices[1].device_type);
    try testing.expect(result.nets[result.getNetIdx("VDD").?.toInt()].is_power);
    try testing.expect(result.nets[result.getNetIdx("VSS").?.toInt()].is_power);
}

// ─── BJT ─────────────────────────────────────────────────────────────────────

test "Parser - BJT NPN 3-terminal" {
    var tok = Tokenizer.init(testing.allocator);
    defer tok.deinit();
    var result = try tok.parse("Q1 collector base emitter npn_model");
    defer result.deinit();
    try testing.expectEqual(@as(usize, 1), result.devices.len);
    try testing.expectEqual(DeviceType.bjt_npn, result.devices[0].device_type);
    try testing.expectEqual(@as(usize, 3), result.pins.len);
}

test "Parser - BJT PNP detected from model name" {
    var tok = Tokenizer.init(testing.allocator);
    defer tok.deinit();
    var result = try tok.parse("Q2 C B E pnp_model");
    defer result.deinit();
    try testing.expectEqual(DeviceType.bjt_pnp, result.devices[0].device_type);
}

test "Parser - BJT NPN with substrate (4-terminal)" {
    var tok = Tokenizer.init(testing.allocator);
    defer tok.deinit();
    var result = try tok.parse("Q1 C B E SUB npn13g2");
    defer result.deinit();
    try testing.expectEqual(DeviceType.bjt_npn, result.devices[0].device_type);
    try testing.expectEqual(@as(usize, 4), result.pins.len);
    // terminals: collector(6) < base(7) < emitter(8), then body(3) gets sorted first
    var saw_collector = false;
    var saw_base = false;
    var saw_emitter = false;
    var saw_body = false;
    for (result.pins) |p| {
        switch (p.terminal) {
            .collector => saw_collector = true,
            .base => saw_base = true,
            .emitter => saw_emitter = true,
            .body => saw_body = true,
            else => {},
        }
    }
    try testing.expect(saw_collector and saw_base and saw_emitter and saw_body);
}

test "Parser - BJT model name case insensitive pnp detection" {
    var tok = Tokenizer.init(testing.allocator);
    defer tok.deinit();
    var result = try tok.parse("Q1 C B E PNP_HV\nQ2 C B E NPN_HV\nQ3 C B E Pnp13g2h");
    defer result.deinit();
    try testing.expectEqual(DeviceType.bjt_pnp, result.devices[0].device_type);
    try testing.expectEqual(DeviceType.bjt_npn, result.devices[1].device_type);
    try testing.expectEqual(DeviceType.bjt_pnp, result.devices[2].device_type);
}

test "Parser - BJT with area and emitter fingers" {
    var tok = Tokenizer.init(testing.allocator);
    defer tok.deinit();
    var result = try tok.parse("Q1 C B E npn13g2 area=2 m=3 ne=4");
    defer result.deinit();
    try testing.expectEqual(@as(f32, 2.0), result.devices[0].params.value);
    try testing.expectEqual(@as(u16, 3), result.devices[0].params.mult);
    try testing.expectEqual(@as(u16, 4), result.devices[0].params.fingers);
}

test "Parser - IHP SG13G2 npn13g2 BiCMOS circuit" {
    var tok = Tokenizer.init(testing.allocator);
    defer tok.deinit();
    var result = try tok.parse(
        \\.subckt bandgap VDD VSS VREF
        \\Q1 VDD net1 net2 VSS npn13g2 m=1 ne=1
        \\Q2 VDD net3 net4 VSS pnp13g2 m=2 ne=1
        \\R1 net2 net4 10k
        \\C1 VREF VSS 1p
        \\.ends bandgap
    );
    defer result.deinit();
    try testing.expectEqual(@as(usize, 4), result.devices.len);
    try testing.expectEqual(DeviceType.bjt_npn, result.devices[0].device_type);
    try testing.expectEqual(DeviceType.bjt_pnp, result.devices[1].device_type);
    try testing.expectEqual(DeviceType.res,     result.devices[2].device_type);
    try testing.expectEqual(DeviceType.cap,     result.devices[3].device_type);
}

// ─── JFET ────────────────────────────────────────────────────────────────────

test "Parser - JFET n-type" {
    var tok = Tokenizer.init(testing.allocator);
    defer tok.deinit();
    var result = try tok.parse("J1 drain gate source njf");
    defer result.deinit();
    try testing.expectEqual(@as(usize, 1), result.devices.len);
    try testing.expectEqual(DeviceType.jfet_n, result.devices[0].device_type);
    try testing.expectEqual(@as(usize, 3), result.pins.len);
}

test "Parser - JFET p-type from model name" {
    var tok = Tokenizer.init(testing.allocator);
    defer tok.deinit();
    var result = try tok.parse("J1 D G S pjf");
    defer result.deinit();
    try testing.expectEqual(DeviceType.jfet_p, result.devices[0].device_type);
}

test "Parser - JFET drain/gate/source terminals" {
    var tok = Tokenizer.init(testing.allocator);
    defer tok.deinit();
    var result = try tok.parse("J1 net_d net_g net_s njf");
    defer result.deinit();
    try testing.expect(result.getNetIdx("net_d") != null);
    try testing.expect(result.getNetIdx("net_g") != null);
    try testing.expect(result.getNetIdx("net_s") != null);
}

// ─── Graceful skip of non-layout devices ─────────────────────────────────────

test "Parser - dependent sources (E/F/G/H) skipped" {
    var tok = Tokenizer.init(testing.allocator);
    defer tok.deinit();
    var result = try tok.parse(
        \\E1 out+ out- in+ in- 10
        \\F1 out+ out- Vsense 5
        \\G1 out+ out- in+ in- 0.01
        \\H1 out+ out- Vsense 100
        \\M1 d g s b nmos w=1u l=1u
    );
    defer result.deinit();
    try testing.expectEqual(@as(usize, 1), result.devices.len);
    try testing.expectEqual(DeviceType.nmos, result.devices[0].device_type);
}

test "Parser - behavioral source (B) skipped" {
    var tok = Tokenizer.init(testing.allocator);
    defer tok.deinit();
    var result = try tok.parse("B1 out 0 V=tanh(v(in))\nM1 d g s b nmos w=1u l=1u");
    defer result.deinit();
    try testing.expectEqual(@as(usize, 1), result.devices.len);
}

test "Parser - mutual inductance (K) skipped" {
    var tok = Tokenizer.init(testing.allocator);
    defer tok.deinit();
    var result = try tok.parse("L1 a b 1n\nL2 c d 1n\nK1 L1 L2 0.9");
    defer result.deinit();
    try testing.expectEqual(@as(usize, 2), result.devices.len);
    try testing.expectEqual(DeviceType.ind, result.devices[0].device_type);
    try testing.expectEqual(DeviceType.ind, result.devices[1].device_type);
}

test "Parser - switches (S/W) skipped" {
    var tok = Tokenizer.init(testing.allocator);
    defer tok.deinit();
    var result = try tok.parse("S1 d s g 0 sw_model\nW1 out 0 Vctl wmod\nM1 d g s b nmos w=1u l=1u");
    defer result.deinit();
    try testing.expectEqual(@as(usize, 1), result.devices.len);
}

test "Parser - transmission lines (T/U) skipped" {
    var tok = Tokenizer.init(testing.allocator);
    defer tok.deinit();
    var result = try tok.parse("T1 a+ a- b+ b- Z0=50 TD=1n\nM1 d g s b nmos w=1u l=1u");
    defer result.deinit();
    try testing.expectEqual(@as(usize, 1), result.devices.len);
}

test "Parser - Xyce Y interface elements skipped" {
    var tok = Tokenizer.init(testing.allocator);
    defer tok.deinit();
    var result = try tok.parse("YLIN y1 a b file=s2p.s2p\nM1 d g s b nmos w=1u l=1u");
    defer result.deinit();
    try testing.expectEqual(@as(usize, 1), result.devices.len);
}

test "Parser - mixed analog circuit: MOSFET + diode + BJT + passives" {
    var tok = Tokenizer.init(testing.allocator);
    defer tok.deinit();
    var result = try tok.parse(
        \\.subckt analog_block VDD VSS IN OUT
        \\M1 net1 IN VSS VSS nmos w=2u l=0.13u
        \\D1 VDD net1 sky130_diode
        \\Q1 net2 net1 VSS npn_model
        \\R1 OUT net2 10k
        \\C1 OUT VSS 100f
        \\.ends analog_block
    );
    defer result.deinit();
    try testing.expectEqual(@as(usize, 5), result.devices.len);
    try testing.expectEqual(DeviceType.nmos,    result.devices[0].device_type);
    try testing.expectEqual(DeviceType.diode,   result.devices[1].device_type);
    try testing.expectEqual(DeviceType.bjt_npn, result.devices[2].device_type);
    try testing.expectEqual(DeviceType.res,     result.devices[3].device_type);
    try testing.expectEqual(DeviceType.cap,     result.devices[4].device_type);
}

// ─── Benchmark file parse tests ──────────────────────────────────────────────

test "Parser - parseFile align_test_vga.spice" {
    var tok = Tokenizer.init(testing.allocator);
    defer tok.deinit();

    var result = tok.parseFile("benchmarks/align_test_vga.spice") catch |err| {
        if (err == ParseError.FileNotFound) return;
        return err;
    };
    defer result.deinit();

    try testing.expectEqual(@as(usize, 7), result.subcircuits.len);
    try testing.expect(result.devices.len > 0);
    try testing.expect(result.nets.len > 0);
}

test "Parser - parseFile align_vco_dtype12_hierarchical.spice" {
    var tok = Tokenizer.init(testing.allocator);
    defer tok.deinit();

    var result = tok.parseFile("benchmarks/align_vco_dtype12_hierarchical.spice") catch |err| {
        if (err == ParseError.FileNotFound) return;
        return err;
    };
    defer result.deinit();

    try testing.expect(result.subcircuits.len > 0);
    try testing.expect(result.devices.len > 0);
    try testing.expect(result.nets.len > 0);
}

// ─── subckt_type field ────────────────────────────────────────────────────────

const subckt_inst_netlist =
    \\.subckt sram_cell bl blb wl vdd vss
    \\M1 bl wl a vss nmos w=0.5u l=0.18u
    \\.ends sram_cell
    \\Xbit_0 bl0 blb0 wl0 vdd vss sram_cell
    \\Xbit_1 bl1 blb1 wl0 vdd vss sram_cell
;

test "parseSubcktInst stores subckt_type on X-instance devices" {
    var tok = Tokenizer.init(testing.allocator);
    defer tok.deinit();
    var result = try tok.parse(subckt_inst_netlist);
    defer result.deinit();

    var found_subckt: usize = 0;
    for (result.devices) |dev| {
        if (dev.device_type == .subckt) {
            try testing.expectEqualStrings("sram_cell", dev.subckt_type);
            found_subckt += 1;
        } else {
            // Non-subckt devices must have empty subckt_type
            try testing.expectEqual(@as(usize, 0), dev.subckt_type.len);
        }
    }
    try testing.expectEqual(@as(usize, 2), found_subckt);
}
