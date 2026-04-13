const std = @import("std");
const types = @import("types.zig");

const PdkId = types.PdkId;
const LayoutBackend = types.LayoutBackend;
const DrcViolation = types.DrcViolation;

// ─── GDSII layer types ──────────────────────────────────────────────────────

/// A GDSII layer/datatype pair.
pub const GdsLayer = extern struct {
    layer: u16,
    datatype: u16,
};

/// Complete GDSII layer table for device-level layout (DRC/LVS/PEX).
pub const LayerTable = extern struct {
    // Well
    nwell: GdsLayer,
    // Active/diffusion
    diff: GdsLayer,
    // Tap diffusion (substrate/well contacts — separate from device diffusion
    // in some PDKs, e.g. SKY130 where diff=65/20 and tap=65/44)
    tap: GdsLayer,
    // Polysilicon
    poly: GdsLayer,
    // Implants
    nsdm: GdsLayer, // N+ source/drain implant
    psdm: GdsLayer, // P+ source/drain implant
    npc: GdsLayer, // Poly contact cut
    // Local interconnect
    licon: GdsLayer, // Contact to diff/poly
    li: GdsLayer, // Local interconnect layer
    mcon: GdsLayer, // Contact from LI to M1
    // Metal stack (5 metals + 4 vias)
    metal: [5]GdsLayer,
    via: [4]GdsLayer,
    // Pin-purpose layers for TEXT labels (used by KLayout LVS)
    li_pin: GdsLayer,
    metal_pin: [5]GdsLayer,
};

// ─── Auxiliary layer DRC rules ──────────────────────────────────────────────

/// Same-layer spacing/width rule for a non-routing (gds_layer, gds_datatype) pair.
/// Used for contacts (licon, mcon), vias (via1-4), and non-routing layers
/// (poly, diff, tap, nsdm, psdm, nwell).
pub const AuxLayerRule = extern struct {
    gds_layer:   u16,
    gds_datatype: u16,
    min_width:   f32,
    min_spacing: f32,
    min_area:    f32,
};

/// Cross-layer spacing rule: shapes on (layer_a, dt_a) must maintain at least
/// `min_spacing` distance from shapes on (layer_b, dt_b).  Used for rules
/// like poly.4 (poly spacing to diffusion) and licon.14 (poly contact to diff).
pub const CrossLayerRule = extern struct {
    layer_a:     u16,
    datatype_a:  u16,
    layer_b:     u16,
    datatype_b:  u16,
    min_spacing: f32,
};

/// Cross-layer enclosure rule: every `inner` shape must be fully enclosed by
/// at least one `outer` shape with extension ≥ `enclosure` on every side.
pub const EnclosureRule = extern struct {
    outer_layer:    u16,
    outer_datatype: u16,
    inner_layer:    u16,
    inner_datatype: u16,
    enclosure:      f32,
};

// ─── PDK configuration ──────────────────────────────────────────────────────

pub const MetalDirection = enum(u8) {
    horizontal = 0,
    vertical = 1,
};

pub const PdkConfig = struct {
    id: PdkId,
    num_metal_layers: u8,
    /// Minimum spacing per layer (index 0 = metal1).
    min_spacing: [8]f32,
    /// Minimum spacing per layer for same-net pairs (index 0 = metal1).
    /// Defaults to zero so legacy static PDK declarations keep compiling;
    /// the JSON loader populates this from ``same_net_spacing``.
    same_net_spacing: [8]f32 = .{0.0} ** 8,
    /// Minimum width per layer.
    min_width: [8]f32,
    /// Via width per layer pair (index 0 = via between metal1 and metal2).
    via_width: [8]f32,
    /// Minimum enclosure per layer.
    min_enclosure: [8]f32,
    /// Minimum area per layer in µm² (index 0 = metal1).
    min_area: [8]f32 = .{0.0} ** 8,
    /// Width threshold per layer: rects wider than this use wide_spacing.
    width_threshold: [8]f32 = .{0.0} ** 8,
    /// Spacing for wide wires (width > width_threshold) per layer.
    wide_spacing: [8]f32 = .{0.0} ** 8,
    /// Minimum via center-to-center spacing per via pair (index 0 = via1-2).
    via_spacing: [8]f32 = .{0.0} ** 8,
    /// Tile size for RUDY (Rectangular Uniform wire Density) estimation.
    tile_size: f32,
    /// Metal pitch per layer.
    metal_pitch: [8]f32,
    /// GDSII database unit in micrometers (typically 0.001).
    db_unit: f32,
    /// Multiplier to convert DeviceParams.w/l to micrometers.
    /// E.g. 1e6 when params are in SI meters, 1.0 when already in microns.
    param_to_um: f32,
    /// Metal thickness per layer in micrometers (index 0 = metal1).
    /// This is the EM/routing thickness used for current-density checks.
    /// Defaults to zero so legacy static PDK declarations keep compiling;
    /// the JSON loader populates this from ``metal_thickness``.
    metal_thickness: [8]f32 = .{0.0} ** 8,
    /// Wire body thickness per metal layer for PEX (µm).  Index 0 = M1.
    /// Kept separate from `metal_thickness` so that PEX coefficients can be
    /// tuned independently of the EM/routing thickness used by the
    /// current-density check.
    wire_thickness: [8]f32 = .{0.0} ** 8,
    /// Inter-layer dielectric (ILD) thickness above each metal (µm).
    /// Index 0 = ILD above M1 (between M1 and M2).
    /// Used by PEX `extractParallelPlateCaps`.
    dielectric_thickness: [8]f32 = .{0.0} ** 8,
    /// Maximum current density per layer in MA/cm^2 (index 0 = metal1).
    /// Defaults to zero so legacy static PDK declarations keep compiling;
    /// the JSON loader populates this from ``j_max``.
    j_max: [8]f32 = .{0.0} ** 8,
    /// Internal layer index -> GDSII layer number.
    layer_map: [8]u16,
    /// Complete GDSII layer table for device-level layout.
    layers: LayerTable,
    /// Guard ring width in micrometers.
    guard_ring_width: f32 = 0.34,
    /// Guard ring spacing from device bounding box in micrometers.
    guard_ring_spacing: f32 = 0.34,
    /// LI-specific minimum spacing (µm).  0 = use min_spacing[0].
    /// SKY130 rule li.3: 0.17 µm.  Only applies when layer == layer_map[0].
    li_min_spacing: f32 = 0.0,
    /// LI-specific minimum width (µm).  0 = use min_width[0].
    /// SKY130 rule li.1: 0.17 µm.  Only applies when layer == layer_map[0].
    li_min_width: f32 = 0.0,
    /// LI-specific minimum area (µm²).  0 = use min_area[0].
    /// SKY130 rule li.2: 0.0561 µm².
    li_min_area: f32 = 0.0,
    /// Auxiliary same-layer DRC rules for contacts, vias, and non-routing layers.
    aux_rules: [24]AuxLayerRule = std.mem.zeroes([24]AuxLayerRule),
    /// Number of valid entries in aux_rules.
    num_aux_rules: u8 = 0,
    /// Cross-layer enclosure rules (outer must enclose inner by ≥ enclosure).
    enc_rules: [16]EnclosureRule = std.mem.zeroes([16]EnclosureRule),
    /// Number of valid entries in enc_rules.
    num_enc_rules: u8 = 0,
    /// Cross-layer spacing rules (shapes on layer_a must maintain min_spacing
    /// from shapes on layer_b).
    cross_rules: [16]CrossLayerRule = std.mem.zeroes([16]CrossLayerRule),
    /// Number of valid entries in cross_rules.
    num_cross_rules: u8 = 0,
    /// Per-layer via/contact resistance in ohms/contact (index 0 = LICON/via0).
    via_resistance: [8]f32 = .{0.0} ** 8,
    /// Per-layer fringe (perimc) capacitance in aF/um (index 0 = M1).
    /// This is the Magic `perimc` coefficient: edge perimeter to substrate.
    fringe_cap: [8]f32 = .{0.0} ** 8,
    /// Per-layer same-layer wire-to-wire coupling capacitance in aF/um
    /// (index 0 = M1).  This is the Magic `sidewall` coefficient — already
    /// calibrated against a 3D field solver.  Used in the 5-term cap model.
    sidewall_cap: [8]f32 = .{0.0} ** 8,
    /// Per-layer wire-to-substrate (areacap) capacitance in aF/um^2
    /// (index 0 = M1).  This is the Magic `areacap` coefficient.
    substrate_cap: [8]f32 = .{0.0} ** 8,
    /// Preferred routing direction per metal layer (index 0 = M1).
    /// Convention: odd-indexed layers (M1, M3, M5) horizontal,
    /// even-indexed layers (M2, M4) vertical.
    /// Override via "metal_direction" in PDK JSON.
    metal_direction: [8]MetalDirection = blk: {
        var dirs: [8]MetalDirection = .{.horizontal} ** 8;
        dirs[1] = .vertical; // M2
        dirs[3] = .vertical; // M4
        dirs[5] = .vertical; // (unused M6, if present)
        dirs[7] = .vertical; // (unused M8, if present)
        break :blk dirs;
    },

    /// Return default values for a known PDK by loading its JSON file.
    /// JSON files live in `src/pdk/` and are resolved relative to the
    /// working directory (project root when running `zig build test`).
    pub fn loadDefault(id: PdkId) PdkConfig {
        const pdk_mod = @import("../pdk/pdk.zig");
        const path = switch (id) {
            .sky130 => "pdks/sky130.json",
            .gf180  => "pdks/gf180.json",
            .ihp130 => "pdks/ihp130.json",
        };
        return pdk_mod.loadFromFile(path, std.heap.page_allocator) catch unreachable;
    }
};

// ─── Callback function pointer types ────────────────────────────────────────

/// DRC callback: takes a pointer to device/route data and a buffer for results.
/// Returns the number of violations written.
pub const DrcCallback = *const fn (
    ctx: ?*anyopaque,
    violations_buf: [*]DrcViolation,
    buf_len: u32,
) callconv(std.builtin.CallingConvention.c) u32;

/// LVS callback: returns true if layout matches schematic.
pub const LvsCallback = *const fn (
    ctx: ?*anyopaque,
) callconv(std.builtin.CallingConvention.c) bool;

/// PEX callback: runs parasitic extraction, writes capacitance values into
/// the provided buffer.  Returns the number of values written.
pub const PexCallback = *const fn (
    ctx: ?*anyopaque,
    cap_buf: [*]f32,
    buf_len: u32,
) callconv(std.builtin.CallingConvention.c) u32;

// ─── LayoutIF comptime interface ────────────────────────────────────────────

pub fn LayoutIF(comptime backend: LayoutBackend) type {
    return struct {
        const Self = @This();

        pdk: PdkConfig,

        /// Opaque context pointer passed to callbacks (typically a Python object).
        ctx: ?*anyopaque,

        /// Callback slots — set by the host (e.g. Python) at init time.
        drc_fn: ?DrcCallback,
        lvs_fn: ?LvsCallback,
        pex_fn: ?PexCallback,

        /// Create a LayoutIF with the given PDK config and null callbacks.
        pub fn init(pdk: PdkConfig) Self {
            return Self{
                .pdk = pdk,
                .ctx = null,
                .drc_fn = null,
                .lvs_fn = null,
                .pex_fn = null,
            };
        }

        /// Register the opaque context pointer.
        pub fn setContext(self: *Self, ctx: ?*anyopaque) void {
            self.ctx = ctx;
        }

        /// Register the DRC callback.
        pub fn setDrcCallback(self: *Self, cb: DrcCallback) void {
            self.drc_fn = cb;
        }

        /// Register the LVS callback.
        pub fn setLvsCallback(self: *Self, cb: LvsCallback) void {
            self.lvs_fn = cb;
        }

        /// Register the PEX callback.
        pub fn setPexCallback(self: *Self, cb: PexCallback) void {
            self.pex_fn = cb;
        }

        /// Run DRC via the registered callback.  Returns violations found.
        pub fn runDrc(self: *const Self, buf: []DrcViolation) ?u32 {
            if (self.drc_fn) |drc| {
                return drc(self.ctx, buf.ptr, @intCast(buf.len));
            }
            return null;
        }

        /// Run LVS via the registered callback.
        pub fn runLvs(self: *const Self) ?bool {
            if (self.lvs_fn) |lvs| {
                return lvs(self.ctx);
            }
            return null;
        }

        /// Run PEX via the registered callback.  Returns number of cap values.
        pub fn runPex(self: *const Self, cap_buf: []f32) ?u32 {
            if (self.pex_fn) |pex| {
                return pex(self.ctx, cap_buf.ptr, @intCast(cap_buf.len));
            }
            return null;
        }

        /// Compile-time backend identifier.
        pub fn backendId() LayoutBackend {
            return backend;
        }
    };
}

// ─── Tests ───────────────────────────────────────────────────────────────────

test "PdkConfig loadDefault sky130" {
    const cfg = PdkConfig.loadDefault(.sky130);
    try std.testing.expectEqual(PdkId.sky130, cfg.id);
    try std.testing.expectEqual(@as(u8, 5), cfg.num_metal_layers);
    try std.testing.expectEqual(@as(f32, 0.14), cfg.min_width[0]);
    try std.testing.expectEqual(@as(f32, 0.001), cfg.db_unit);
}

test "PdkConfig loadDefault gf180" {
    const cfg = PdkConfig.loadDefault(.gf180);
    try std.testing.expectEqual(PdkId.gf180, cfg.id);
    try std.testing.expectEqual(@as(u8, 5), cfg.num_metal_layers);
    try std.testing.expectEqual(@as(f32, 0.23), cfg.min_spacing[0]);
}

test "PdkConfig loadDefault ihp130" {
    const cfg = PdkConfig.loadDefault(.ihp130);
    try std.testing.expectEqual(PdkId.ihp130, cfg.id);
    try std.testing.expectEqual(@as(u8, 5), cfg.num_metal_layers);
}

test "LayoutIF magic init" {
    const MagicLayout = LayoutIF(.magic);
    const pdk = PdkConfig.loadDefault(.sky130);
    var lif = MagicLayout.init(pdk);

    try std.testing.expectEqual(LayoutBackend.magic, MagicLayout.backendId());
    try std.testing.expectEqual(@as(?*anyopaque, null), lif.ctx);

    // No callbacks registered → null returns.
    try std.testing.expectEqual(@as(?u32, null), lif.runDrc(&[_]DrcViolation{}));
    try std.testing.expectEqual(@as(?bool, null), lif.runLvs());
    try std.testing.expectEqual(@as(?u32, null), lif.runPex(&[_]f32{}));
}

test "LayoutIF klayout init" {
    const KLayout = LayoutIF(.klayout);
    const pdk = PdkConfig.loadDefault(.gf180);
    const lif = KLayout.init(pdk);

    try std.testing.expectEqual(LayoutBackend.klayout, KLayout.backendId());
    try std.testing.expectEqual(PdkId.gf180, lif.pdk.id);
}

test "PdkConfig sky130 sensible values" {
    const cfg = PdkConfig.loadDefault(.sky130);

    // Verify num_metal_layers
    try std.testing.expectEqual(@as(u8, 5), cfg.num_metal_layers);

    // Verify min_spacing[0] is a reasonable value (positive, < 1um)
    try std.testing.expect(cfg.min_spacing[0] > 0.0);
    try std.testing.expect(cfg.min_spacing[0] < 1.0);
    try std.testing.expectEqual(@as(f32, 0.14), cfg.min_spacing[0]);

    // Verify min_width[0] is a reasonable value
    try std.testing.expect(cfg.min_width[0] > 0.0);
    try std.testing.expect(cfg.min_width[0] < 1.0);
    try std.testing.expectEqual(@as(f32, 0.14), cfg.min_width[0]);

    // Verify db_unit
    try std.testing.expectEqual(@as(f32, 0.001), cfg.db_unit);

    // Verify tile_size
    try std.testing.expectEqual(@as(f32, 1.0), cfg.tile_size);

    // Higher layers have larger spacing/width
    try std.testing.expect(cfg.min_spacing[2] >= cfg.min_spacing[0]);
    try std.testing.expect(cfg.min_width[4] >= cfg.min_width[0]);
}

test "PdkConfig all three PDKs have 5 metal layers" {
    const sky = PdkConfig.loadDefault(.sky130);
    const gf = PdkConfig.loadDefault(.gf180);
    const ihp = PdkConfig.loadDefault(.ihp130);

    try std.testing.expectEqual(@as(u8, 5), sky.num_metal_layers);
    try std.testing.expectEqual(@as(u8, 5), gf.num_metal_layers);
    try std.testing.expectEqual(@as(u8, 5), ihp.num_metal_layers);
}

test "PdkConfig layer_map values are non-zero for active layers" {
    const cfg = PdkConfig.loadDefault(.sky130);

    // First 5 layers should have non-zero GDSII layer numbers
    for (0..5) |i| {
        try std.testing.expect(cfg.layer_map[i] > 0);
    }
    // Unused layers should be zero
    for (5..8) |i| {
        try std.testing.expectEqual(@as(u16, 0), cfg.layer_map[i]);
    }
}

test "PdkConfig metal_pitch is positive for active layers" {
    const cfg = PdkConfig.loadDefault(.sky130);

    for (0..5) |i| {
        try std.testing.expect(cfg.metal_pitch[i] > 0.0);
    }
}

test "PdkConfig via_width is positive for via pairs" {
    const cfg = PdkConfig.loadDefault(.sky130);

    // Via widths for the first 4 via pairs
    for (0..4) |i| {
        try std.testing.expect(cfg.via_width[i] > 0.0);
    }
}

test "PdkConfig metal_direction defaults" {
    const cfg = PdkConfig.loadDefault(.sky130);
    // Convention: odd layers (0,2,4) = horizontal, even layers (1,3) = vertical
    try std.testing.expectEqual(MetalDirection.horizontal, cfg.metal_direction[0]); // M1
    try std.testing.expectEqual(MetalDirection.vertical, cfg.metal_direction[1]); // M2
    try std.testing.expectEqual(MetalDirection.horizontal, cfg.metal_direction[2]); // M3
    try std.testing.expectEqual(MetalDirection.vertical, cfg.metal_direction[3]); // M4
    try std.testing.expectEqual(MetalDirection.horizontal, cfg.metal_direction[4]); // M5
}

test "LayoutIF setContext and callbacks" {
    const MagicLayout = LayoutIF(.magic);
    const pdk = PdkConfig.loadDefault(.sky130);
    var lif = MagicLayout.init(pdk);

    // Initially null
    try std.testing.expectEqual(@as(?*anyopaque, null), lif.ctx);

    // Set a non-null context (we just use an arbitrary pointer)
    var dummy: u32 = 42;
    lif.setContext(&dummy);
    try std.testing.expect(lif.ctx != null);
}
