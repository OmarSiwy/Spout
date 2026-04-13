// characterize/types.zig
//
// Shared types for the DRC / LVS / PEX characterization modules.
//
// Reference implementations studied:
//   Magic DRC  — RTimothyEdwards/magic  drc/drc.h, drc/DRCbasic.c
//   Magic PEX  — RTimothyEdwards/magic  extract/extractInt.h, extract/ExtBasic.c
//   Netgen LVS — RTimothyEdwards/netgen netgen/netcomp.c

const std = @import("std");

// ─── Re-exports from core ─────────────────────────────────────────────────────

pub const DrcViolation = @import("../core/types.zig").DrcViolation;
pub const DrcRule      = @import("../core/types.zig").DrcRule;
pub const DrcMetric    = @import("../core/types.zig").DrcMetric;
pub const NetIdx       = @import("../core/types.zig").NetIdx;
pub const DeviceIdx    = @import("../core/types.zig").DeviceIdx;
pub const DeviceType   = @import("../core/types.zig").DeviceType;
pub const DeviceParams = @import("../core/types.zig").DeviceParams;

// ─── LVS types ───────────────────────────────────────────────────────────────
//
// Mirrors Netgen's device comparison result categories (netcomp.c).

pub const LvsStatus = enum(u8) {
    match                      = 0,
    device_count_mismatch      = 1,
    device_type_mismatch       = 2,
    net_connectivity_mismatch  = 3,
    parameter_mismatch         = 4,
};

/// Summary report returned by LvsChecker.compare*.
/// Mirrors Netgen's mismatch classification.
pub const LvsReport = struct {
    matched:              u32,
    /// Devices present in layout but absent from schematic.
    unmatched_layout:     u32,
    /// Devices present in schematic but absent from layout.
    unmatched_schematic:  u32,
    /// Nets whose connectivity differs between layout and schematic.
    net_mismatches:       u32,
    pass:                 bool,
};

// ─── PEX types ────────────────────────────────────────────────────────────────
//
// The 5-term capacitance model used by Magic (ExtBasic.c):
//   C = area * areacap  +  perimeter * perimc  +  overlap * sidewall
//
// Resistance from ExtBasic.c/ExtTech.c:
//   R = sheet_resistance * (length / width)   [per segment]
//   R_via = via_resistance / n_cuts            [per via stack]

/// Parasitic extraction technology coefficients.
/// All cap values in aF (attofarads), resistance in Ω/sq.
pub const PexConfig = struct {
    /// Sheet resistance per routing layer in Ω/sq.
    /// Index 0 = M1 (route layer 1), 1 = M2, …
    sheet_resistance: [8]f32 = .{0.0} ** 8,
    /// Area capacitance to substrate per layer in aF/µm².
    /// Matches Magic's `areacap` coefficient.  Index 0 = M1.
    substrate_cap: [8]f32 = .{0.0} ** 8,
    /// Fringe (perimeter) capacitance per layer in aF/µm of edge length.
    /// Matches Magic's `perimc` coefficient.  Index 0 = M1.
    fringe_cap: [8]f32 = .{0.0} ** 8,
    /// Sidewall coupling capacitance per layer in aF/µm of parallel run.
    /// Matches Magic's `sidecouple` coefficient.  Index 0 = M1.
    sidewall_cap: [8]f32 = .{0.0} ** 8,
    /// Maximum perpendicular separation (µm) within which sidewall coupling is
    /// counted.  Wires farther apart than this in the perpendicular direction
    /// are not coupled.  0.0 = no cutoff (unlimited, backward-compatible default).
    /// Matches Magic's `sidecouple` coupling-distance parameter in the tech file.
    coupling_distance: [8]f32 = .{0.0} ** 8,
    /// Additive offset (µm) in the distance-dependent coupling formula.
    /// When > 0, coupling cap is computed as:
    ///   C = sw_cap * overlap * offset / (perp + offset)
    /// matching Magic's ExtCouple.c `extSideCommon`:  cap = ec_cap * overlap / (sep + ec_offset).
    /// At perp = 0 the result equals sw_cap * overlap (unchanged from flat model).
    /// 0.0 = flat model (no distance decay, backward-compatible default).
    coupling_offset: [8]f32 = .{0.0} ** 8,

    /// Via/contact resistance in Ω per cut.
    /// Index 0 = mcon (LI→M1), 1 = v1 (M1→M2), 2 = v2 (M2→M3), …
    /// From Magic tech file: `contact <type> <milliohms>`.
    /// R_via = via_resistance / n_cuts  (we assume 1 cut per via point).
    via_resistance: [8]f32 = .{0.0} ** 8,

    /// Interlayer overlap (parallel-plate) capacitance in aF/µm².
    /// Index i = overlap cap between route layer i and route layer i+1.
    /// From Magic tech file `defaultoverlap` entries (e.g., "allm1 metal1 allli locali 114.20").
    /// Computed as: C_overlap = overlap_area * overlap_cap[lower_layer]
    overlap_cap: [8]f32 = .{0.0} ** 8,

    /// SKY130 coefficients calibrated against sky130A.tech Magic technology file.
    /// Sheet resistance: LI=12.8, M1-M2=0.125, M3-M4=0.047, M5=0.029 Ω/sq.
    /// Cap coefficients from Magic's `extract style` section in sky130A.tech.
    /// Coupling halo: `sidehalo 8` in tech file = 8µm search range.
    /// Coupling offset: 4th arg of `defaultsidewall` (ec_offset in ExtTech.c).
    /// Via resistance from `contact` entries (typical variant, milliohms → Ω).
    pub fn sky130() PexConfig {
        return .{
            // Values from $PDK_ROOT/sky130A/libs.tech/magic/sky130A.tech extract section.
            // Index 0 = LI (locali), 1 = M1, 2 = M2, 3 = M3, 4 = M4, 5 = M5.
            // LI: resist (allli)/locali 12800 mΩ/sq = 12.8 Ω/sq
            // M1-M2: 125 mΩ/sq = 0.125 Ω/sq; M3-M4: 47 mΩ/sq; M5: 29 mΩ/sq.
            .sheet_resistance  = .{ 12.8,  0.125, 0.125, 0.047, 0.047, 0.029, 0.0, 0.0 },
            // LI: defaultareacap allli locali 36.99 aF/µm²
            // M1: 25.78, M2: 17.50, M3: 12.37, M4: 8.42, M5: 6.32
            .substrate_cap     = .{ 36.99, 25.78, 17.50, 12.37,  8.42,  6.32, 0.0, 0.0 },
            // LI: defaultperimeter allli locali 40.70 aF/µm
            // M1: 40.57, M2: 37.76, M3: 40.99, M4: 36.68, M5: 38.85
            .fringe_cap        = .{ 40.70, 40.57, 37.76, 40.99, 36.68, 38.85, 0.0, 0.0 },
            // LI: defaultsidewall allli locali 25.5 aF/µm (offset 0.14)
            // M1: 44.0, M2: 50.0, M3: 74.0, M4: 94.0, M5: 155.0
            .sidewall_cap      = .{ 25.5,  44.0,  50.0,  74.0,  94.0, 155.0,  0.0, 0.0 },
            // Coupling search halo per layer — limits max edge-to-edge distance
            // for sidewall coupling.  Magic's `sidehalo 8` is 8 internal extract
            // units = 0.08 µm per edge, so effective max coupling distance is
            // approximately 1 minimum spacing per layer.  Larger values cause
            // massive overcounting of coupling cap on dense circuits.
            .coupling_distance = .{ 0.17,  0.20,  0.20,  0.30,  0.30,  1.6,   0.0, 0.0 },
            // ec_offset from `defaultsidewall` 4th arg (µm).  Used in denominator:
            // C = ec_cap * overlap / (sep_ee + ec_offset).
            // ExtTech.c line 3882: ec_cap *= 0.5 (halved for double-walk), but
            // Spout counts each pair once so uses the full tech-file value.
            // LI: 0.14, M1: 0.25, M2: 0.30, M3: 0.40, M4: 0.57, M5: 0.50
            .coupling_offset   = .{ 0.14,  0.25,  0.30,  0.40,  0.57,  0.50,  0.0, 0.0 },
            // Via resistance from tech file `contact` entries (typical variant).
            // mcon (LI→M1): 9300 mΩ = 9.3 Ω
            // v1 (M1→M2): 4500 mΩ = 4.5 Ω; v2 (M2→M3): 3410 mΩ = 3.41 Ω
            // via3 (M3→M4): 3410 mΩ = 3.41 Ω; via4 (M4→M5): 380 mΩ = 0.38 Ω
            .via_resistance    = .{ 9.3,   4.5,   3.41,  3.41,  0.38,  0.0,   0.0, 0.0 },
            // Interlayer overlap cap from tech file `defaultoverlap` entries (aF/µm²).
            // Index i = cap between route layer i and route layer i+1.
            // LI↔M1: 114.20, M1↔M2: 133.86, M2↔M3: 86.19, M3↔M4: 84.03, M4↔M5: 68.33
            .overlap_cap       = .{ 114.20, 133.86, 86.19, 84.03, 68.33, 0.0, 0.0, 0.0 },
        };
    }
};

/// A single parasitic element (R or C) between two nets.
/// For capacitors to substrate, use net_b = SUBSTRATE_NET.
pub const RcElement = struct {
    net_a:  u32,
    net_b:  u32,
    /// Value in ohms (R) or femtofarads (C, converted from aF).
    value:  f32,
};

/// Substrate net sentinel — capacitance target when shielding net is substrate.
pub const SUBSTRATE_NET: u32 = std.math.maxInt(u32) - 1;

/// PEX extraction output.  Caller owns the slices; call deinit() when done.
pub const PexResult = struct {
    resistors:   []RcElement,
    capacitors:  []RcElement,
    /// Net merge map from short detection (parallel arrays: from[i] → to[i]).
    merge_from:  ?[]u32 = null,
    merge_to:    ?[]u32 = null,
    allocator:   std.mem.Allocator,

    /// Look up the merged (root) net for an original net ID.
    pub fn mergedNet(self: *const PexResult, net: u32) u32 {
        const from = self.merge_from orelse return net;
        const to = self.merge_to orelse return net;
        for (from, to) |f, t| {
            if (f == net) return t;
        }
        return net;
    }

    pub fn deinit(self: *PexResult) void {
        self.allocator.free(self.resistors);
        self.allocator.free(self.capacitors);
        if (self.merge_from) |m| self.allocator.free(m);
        if (self.merge_to) |m| self.allocator.free(m);
        self.* = undefined;
    }
};

// ─── Tests ───────────────────────────────────────────────────────────────────

test "PexConfig sky130 sheet resistance LI" {
    const cfg = PexConfig.sky130();
    // LI sheet resistance = 12.8 Ω/sq (index 0)
    try std.testing.expectApproxEqAbs(@as(f32, 12.8), cfg.sheet_resistance[0], 1e-3);
}

test "PexConfig sky130 sheet resistance M1" {
    const cfg = PexConfig.sky130();
    // M1 sheet resistance = 0.125 Ω/sq (index 1)
    try std.testing.expectApproxEqAbs(@as(f32, 0.125), cfg.sheet_resistance[1], 1e-6);
}

test "PexConfig sky130 M4 lower sheet resistance than M1" {
    const cfg = PexConfig.sky130();
    // M4 (index 4) = 0.047 Ω/sq < M1 (index 1) = 0.125 Ω/sq
    try std.testing.expect(cfg.sheet_resistance[4] < cfg.sheet_resistance[1]);
}

test "PexConfig sky130 substrate cap decreases with layer height" {
    const cfg = PexConfig.sky130();
    // Higher layers are farther from substrate → lower area cap
    // LI (0) > M5 (5)
    try std.testing.expect(cfg.substrate_cap[0] > cfg.substrate_cap[5]);
}

test "PexConfig sky130 fringe cap non-zero for all layers" {
    const cfg = PexConfig.sky130();
    // LI (0) through M5 (5) = 6 layers
    for (0..6) |i| {
        try std.testing.expect(cfg.fringe_cap[i] > 0.0);
    }
}

test "PexConfig sky130 via resistance mcon" {
    const cfg = PexConfig.sky130();
    // mcon (LI→M1) = 9.3 Ω (index 0)
    try std.testing.expectApproxEqAbs(@as(f32, 9.3), cfg.via_resistance[0], 1e-3);
}

test "LvsReport pass field" {
    const r = LvsReport{
        .matched             = 4,
        .unmatched_layout    = 0,
        .unmatched_schematic = 0,
        .net_mismatches      = 0,
        .pass                = true,
    };
    try std.testing.expect(r.pass);
    try std.testing.expectEqual(@as(u32, 4), r.matched);
}

test "SUBSTRATE_NET sentinel is not a normal net index" {
    // Must not be equal to any realistic net count
    try std.testing.expect(SUBSTRATE_NET > 1_000_000);
}

test "RcElement fields accessible" {
    const e = RcElement{ .net_a = 1, .net_b = SUBSTRATE_NET, .value = 3.14 };
    try std.testing.expectEqual(@as(u32, 1), e.net_a);
    try std.testing.expectEqual(SUBSTRATE_NET, e.net_b);
    try std.testing.expectApproxEqAbs(@as(f32, 3.14), e.value, 1e-5);
}
