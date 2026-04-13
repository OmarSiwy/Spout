const std = @import("std");

// ─── Index newtypes ───────────────────────────────────────────────────────────
//
// Each type is a distinct enum(Int).  Separate definitions guarantee
// type-safety — DeviceIdx and NetIdx are both enum(u32) but cannot be
// accidentally mixed.  The toInt/fromInt boilerplate is intentionally
// repeated per type; Zig 0.15 does not support usingnamespace in enum bodies.

pub const DeviceIdx = enum(u32) {
    _,
    pub inline fn toInt(self: DeviceIdx) u32 { return @intFromEnum(self); }
    pub inline fn fromInt(v: u32) DeviceIdx { return @enumFromInt(v); }
};

pub const NetIdx = enum(u32) {
    _,
    pub inline fn toInt(self: NetIdx) u32 { return @intFromEnum(self); }
    pub inline fn fromInt(v: u32) NetIdx { return @enumFromInt(v); }
};

pub const PinIdx = enum(u32) {
    _,
    pub inline fn toInt(self: PinIdx) u32 { return @intFromEnum(self); }
    pub inline fn fromInt(v: u32) PinIdx { return @enumFromInt(v); }
};

pub const ConstraintIdx = enum(u32) {
    _,
    pub inline fn toInt(self: ConstraintIdx) u32 { return @intFromEnum(self); }
    pub inline fn fromInt(v: u32) ConstraintIdx { return @enumFromInt(v); }
};

pub const LayerIdx = enum(u16) {
    _,
    pub inline fn toInt(self: LayerIdx) u16 { return @intFromEnum(self); }
    pub inline fn fromInt(v: u16) LayerIdx { return @enumFromInt(v); }
};

pub const PolygonIdx = enum(u32) {
    _,
    pub inline fn toInt(self: PolygonIdx) u32 { return @intFromEnum(self); }
    pub inline fn fromInt(v: u32) PolygonIdx { return @enumFromInt(v); }
};

pub const EdgeIdx = enum(u32) {
    _,
    pub inline fn toInt(self: EdgeIdx) u32 { return @intFromEnum(self); }
    pub inline fn fromInt(v: u32) EdgeIdx { return @enumFromInt(v); }
};

// ─── Device / terminal / constraint enums ─────────────────────────────────────

pub const DeviceType = enum(u8) {
    // ── MOSFETs ──────────────────────────────────────────────────────────────
    nmos = 0,
    pmos = 1,
    // ── Generic passives (no physical model specified) ────────────────────
    res = 2,
    cap = 3,
    ind = 4,
    // ── Structural ───────────────────────────────────────────────────────
    subckt = 5,
    // ── Other active devices ─────────────────────────────────────────────
    diode = 6,
    bjt_npn = 7,
    bjt_pnp = 8,
    jfet_n = 9,
    jfet_p = 10,
    // ── Resistor physical subtypes ────────────────────────────────────────
    // Geometry: rectangular (w × l), using w/l params or value/sheet-R estimate.
    res_poly   = 11,  // polysilicon (high-R, silicided, etc.)
    res_diff_n = 12,  // n+ diffusion / n-implant
    res_diff_p = 13,  // p+ diffusion / p-implant
    res_well_n = 14,  // n-well (large footprint, needs isolation)
    res_well_p = 15,  // p-well / iso p-well
    res_metal  = 16,  // metal layer resistor (li1, rm1-rm5, etc.)
    // ── Capacitor physical subtypes ───────────────────────────────────────
    // Geometry: rectangular (w × l) or sqrt(C/density) if only value given.
    cap_mim  = 17,  // metal-insulator-metal (on specific upper metal layers)
    cap_mom  = 18,  // metal-oxide-metal / fringe cap (interdigitated)
    cap_pip  = 19,  // poly-insulator-poly
    cap_gate = 20,  // MOSFET gate capacitor (sized like a MOSFET, w × l)
};

pub const TerminalType = enum(u8) {
    gate = 0,
    drain = 1,
    source = 2,
    body = 3,
    anode = 4,
    cathode = 5,
    collector = 6,
    base = 7,
    emitter = 8,
};

pub const ConstraintType = enum(u8) {
    symmetry = 0,
    matching = 1,
    proximity = 2,
    isolation = 3,
};

// ─── Device parameters (C-ABI compatible) ─────────────────────────────────────

pub const DeviceParams = extern struct {
    w: f32,
    l: f32,
    fingers: u16,
    mult: u16,
    value: f32,
};

// ─── Layout / PDK enums ──────────────────────────────────────────────────────

pub const LayoutBackend = enum(u8) {
    magic = 0,
    klayout = 1,
};

pub const PdkId = enum(u8) {
    sky130 = 0,
    gf180 = 1,
    ihp130 = 2,
};

// ─── DRC types (C-ABI compatible) ────────────────────────────────────────────

pub const DrcRule = enum(u8) {
    min_spacing = 0,
    min_width = 1,
    min_enclosure = 2,
    min_area = 3,
    short = 4,
    notch = 5,
    same_net_spacing = 6,
    enclosing_second_edges = 7,
    separation = 8,
    hole_area = 9,
};

/// Metric used to measure edge-to-edge distance.  Mirrors KLayout's
/// `Region::Metrics` enum: euclidian, projection, square (Chebyshev).
pub const DrcMetric = enum(u8) {
    euclidian = 0,
    projection = 1,
    square = 2,
};

pub const DrcViolation = extern struct {
    rule: DrcRule,
    layer: u8,
    x: f32,
    y: f32,
    actual: f32,
    required: f32,
    rect_a: u32,
    rect_b: u32,
};

// ─── Tests ───────────────────────────────────────────────────────────────────

test "DeviceIdx round-trip" {
    const idx = DeviceIdx.fromInt(42);
    try std.testing.expectEqual(@as(u32, 42), idx.toInt());
}

test "NetIdx round-trip" {
    const idx = NetIdx.fromInt(7);
    try std.testing.expectEqual(@as(u32, 7), idx.toInt());
}

test "PinIdx round-trip" {
    const idx = PinIdx.fromInt(0);
    try std.testing.expectEqual(@as(u32, 0), idx.toInt());
}

test "ConstraintIdx round-trip" {
    const idx = ConstraintIdx.fromInt(999);
    try std.testing.expectEqual(@as(u32, 999), idx.toInt());
}

test "LayerIdx round-trip" {
    const idx = LayerIdx.fromInt(42);
    try std.testing.expectEqual(@as(u16, 42), idx.toInt());
}

test "PolygonIdx round-trip" {
    const idx = PolygonIdx.fromInt(0xDEADBEEF);
    try std.testing.expectEqual(@as(u32, 0xDEADBEEF), idx.toInt());
}

test "EdgeIdx round-trip" {
    const idx = EdgeIdx.fromInt(1234);
    try std.testing.expectEqual(@as(u32, 1234), idx.toInt());
}

test "DrcMetric enum values" {
    try std.testing.expectEqual(@as(u8, 0), @intFromEnum(DrcMetric.euclidian));
    try std.testing.expectEqual(@as(u8, 1), @intFromEnum(DrcMetric.projection));
    try std.testing.expectEqual(@as(u8, 2), @intFromEnum(DrcMetric.square));
}

test "DrcRule extended enum values" {
    try std.testing.expectEqual(@as(u8, 5), @intFromEnum(DrcRule.notch));
    try std.testing.expectEqual(@as(u8, 6), @intFromEnum(DrcRule.same_net_spacing));
    try std.testing.expectEqual(@as(u8, 7), @intFromEnum(DrcRule.enclosing_second_edges));
    try std.testing.expectEqual(@as(u8, 8), @intFromEnum(DrcRule.separation));
    try std.testing.expectEqual(@as(u8, 9), @intFromEnum(DrcRule.hole_area));
}

test "DeviceParams is extern-compatible" {
    // extern structs must have a deterministic layout; verify size.
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(DeviceParams));
}

test "DrcViolation is extern-compatible" {
    // 1+1+4+4+4+4+4+4 = 26 → padded to 28 with alignment
    try std.testing.expect(@sizeOf(DrcViolation) <= 32);
}

// ─── Additional round-trip tests ────────────────────────────────────────────

test "DeviceIdx round-trip at boundary values" {
    // Test with 0
    try std.testing.expectEqual(@as(u32, 0), DeviceIdx.fromInt(0).toInt());
    // Test with max-ish value
    try std.testing.expectEqual(@as(u32, 0xFFFFFFFF), DeviceIdx.fromInt(0xFFFFFFFF).toInt());
    // Test mid value
    try std.testing.expectEqual(@as(u32, 100000), DeviceIdx.fromInt(100000).toInt());
}

test "NetIdx round-trip at boundary values" {
    try std.testing.expectEqual(@as(u32, 0), NetIdx.fromInt(0).toInt());
    try std.testing.expectEqual(@as(u32, 0xFFFFFFFF), NetIdx.fromInt(0xFFFFFFFF).toInt());
    try std.testing.expectEqual(@as(u32, 500), NetIdx.fromInt(500).toInt());
}

test "PinIdx round-trip at boundary values" {
    try std.testing.expectEqual(@as(u32, 0), PinIdx.fromInt(0).toInt());
    try std.testing.expectEqual(@as(u32, 0xFFFFFFFF), PinIdx.fromInt(0xFFFFFFFF).toInt());
    try std.testing.expectEqual(@as(u32, 12345), PinIdx.fromInt(12345).toInt());
}

test "ConstraintIdx round-trip at boundary values" {
    try std.testing.expectEqual(@as(u32, 0), ConstraintIdx.fromInt(0).toInt());
    try std.testing.expectEqual(@as(u32, 0xFFFFFFFF), ConstraintIdx.fromInt(0xFFFFFFFF).toInt());
}

test "DeviceParams extern struct size is 16 bytes" {
    // w(4) + l(4) + fingers(2) + mult(2) + value(4) = 16
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(DeviceParams));
}

test "DeviceParams fields have expected offsets" {
    // Verify the extern struct layout is deterministic
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(DeviceParams, "w"));
    try std.testing.expectEqual(@as(usize, 4), @offsetOf(DeviceParams, "l"));
    try std.testing.expectEqual(@as(usize, 8), @offsetOf(DeviceParams, "fingers"));
    try std.testing.expectEqual(@as(usize, 10), @offsetOf(DeviceParams, "mult"));
    try std.testing.expectEqual(@as(usize, 12), @offsetOf(DeviceParams, "value"));
}

test "DeviceType enum values" {
    try std.testing.expectEqual(@as(u8, 0), @intFromEnum(DeviceType.nmos));
    try std.testing.expectEqual(@as(u8, 1), @intFromEnum(DeviceType.pmos));
    try std.testing.expectEqual(@as(u8, 2), @intFromEnum(DeviceType.res));
    try std.testing.expectEqual(@as(u8, 3), @intFromEnum(DeviceType.cap));
    try std.testing.expectEqual(@as(u8, 4), @intFromEnum(DeviceType.ind));
    try std.testing.expectEqual(@as(u8, 5), @intFromEnum(DeviceType.subckt));
}

test "TerminalType enum values" {
    try std.testing.expectEqual(@as(u8, 0), @intFromEnum(TerminalType.gate));
    try std.testing.expectEqual(@as(u8, 1), @intFromEnum(TerminalType.drain));
    try std.testing.expectEqual(@as(u8, 2), @intFromEnum(TerminalType.source));
    try std.testing.expectEqual(@as(u8, 3), @intFromEnum(TerminalType.body));
    try std.testing.expectEqual(@as(u8, 4), @intFromEnum(TerminalType.anode));
    try std.testing.expectEqual(@as(u8, 5), @intFromEnum(TerminalType.cathode));
}

test "ConstraintType enum values" {
    try std.testing.expectEqual(@as(u8, 0), @intFromEnum(ConstraintType.symmetry));
    try std.testing.expectEqual(@as(u8, 1), @intFromEnum(ConstraintType.matching));
    try std.testing.expectEqual(@as(u8, 2), @intFromEnum(ConstraintType.proximity));
    try std.testing.expectEqual(@as(u8, 3), @intFromEnum(ConstraintType.isolation));
}

test "DrcViolation extern struct field presence" {
    // Verify we can construct a DrcViolation
    const v = DrcViolation{
        .rule = .min_spacing,
        .layer = 1,
        .x = 1.5,
        .y = 2.5,
        .actual = 0.1,
        .required = 0.15,
        .rect_a = 0,
        .rect_b = 1,
    };
    try std.testing.expectEqual(DrcRule.min_spacing, v.rule);
    try std.testing.expectEqual(@as(u8, 1), v.layer);
    try std.testing.expectEqual(@as(f32, 1.5), v.x);
    try std.testing.expectEqual(@as(f32, 2.5), v.y);
}
