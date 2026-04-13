//! Centralized PDK registry.
//!
//! PDK configurations are loaded at runtime from JSON files.  Reference JSON
//! templates for sky130, gf180, and ihp130 live in `src/pdk/`.  Users provide
//! a path to whichever JSON file they want via `loadFromFile`, or from the
//! Python side via `spout_load_pdk_from_file`.

const std = @import("std");
const layout_if = @import("../core/layout_if.zig");
const types = @import("../core/types.zig");
const json_parser = @import("json_parser.zig");

// ── Re-export core types so callers can write `pdk.PdkConfig` etc. ──────────

pub const PdkConfig = layout_if.PdkConfig;
pub const GdsLayer = layout_if.GdsLayer;
pub const LayerTable = layout_if.LayerTable;
pub const PdkId = types.PdkId;
pub const MetalDirection = layout_if.MetalDirection;

// ── PDK parameter name → tag map (O(1) lookup) ───────────────────────────────

/// Identifies a named scalar or array field in `PdkConfig`.
pub const PdkParamId = enum {
    num_metal_layers,
    db_unit,
    param_to_um,
    tile_size,
    guard_ring_width,
    guard_ring_spacing,
    min_spacing,
    same_net_spacing,
    min_width,
    via_width,
    min_enclosure,
    min_area,
    width_threshold,
    wide_spacing,
    via_spacing,
    metal_pitch,
    metal_thickness,
    wire_thickness,
    dielectric_thickness,
    j_max,
    via_resistance,
    fringe_cap,
    sidewall_cap,
    substrate_cap,
    layer_map,
    metal_direction,
    layers,
    li_min_spacing,
    li_min_width,
    li_min_area,
    aux_rules,
    enc_rules,
    cross_rules,
};

/// Static O(1) map from parameter name string to `PdkParamId` tag.
///
/// Usage:
/// ```zig
/// if (pdk.PARAM_MAP.get("min_spacing")) |id| {
///     _ = id; // .min_spacing
/// }
/// ```
pub const PARAM_MAP = std.StaticStringMap(PdkParamId).initComptime(&.{
    .{ "num_metal_layers",     .num_metal_layers },
    .{ "db_unit",              .db_unit },
    .{ "param_to_um",          .param_to_um },
    .{ "tile_size",            .tile_size },
    .{ "guard_ring_width",     .guard_ring_width },
    .{ "guard_ring_spacing",   .guard_ring_spacing },
    .{ "min_spacing",          .min_spacing },
    .{ "same_net_spacing",     .same_net_spacing },
    .{ "min_width",            .min_width },
    .{ "via_width",            .via_width },
    .{ "min_enclosure",        .min_enclosure },
    .{ "min_area",             .min_area },
    .{ "width_threshold",      .width_threshold },
    .{ "wide_spacing",         .wide_spacing },
    .{ "via_spacing",          .via_spacing },
    .{ "metal_pitch",          .metal_pitch },
    .{ "metal_thickness",      .metal_thickness },
    .{ "wire_thickness",       .wire_thickness },
    .{ "dielectric_thickness", .dielectric_thickness },
    .{ "j_max",                .j_max },
    .{ "via_resistance",       .via_resistance },
    .{ "fringe_cap",           .fringe_cap },
    .{ "sidewall_cap",         .sidewall_cap },
    .{ "substrate_cap",        .substrate_cap },
    .{ "layer_map",            .layer_map },
    .{ "metal_direction",      .metal_direction },
    .{ "layers",               .layers },
    .{ "li_min_spacing",       .li_min_spacing },
    .{ "li_min_width",         .li_min_width },
    .{ "li_min_area",          .li_min_area },
    .{ "aux_rules",            .aux_rules },
    .{ "enc_rules",            .enc_rules },
    .{ "cross_rules",          .cross_rules },
});

// ── Loader ───────────────────────────────────────────────────────────────────

/// Load a `PdkConfig` from a JSON file at `path`.
///
/// `allocator` is used only for temporary JSON parsing scratch; the returned
/// `PdkConfig` owns no heap memory.  Returns an error if the file cannot be
/// read or the JSON is malformed.
pub fn loadFromFile(path: []const u8, allocator: std.mem.Allocator) !PdkConfig {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    const json_bytes = try file.readToEndAlloc(allocator, 1024 * 1024); // 1 MiB max
    defer allocator.free(json_bytes);
    return json_parser.parseCustomPdk(json_bytes, allocator);
}

// ── Tests ───────────────────────────────────────────────────────────────────

test "PARAM_MAP resolves all field names" {
    try std.testing.expectEqual(PdkParamId.min_spacing,     PARAM_MAP.get("min_spacing").?);
    try std.testing.expectEqual(PdkParamId.db_unit,         PARAM_MAP.get("db_unit").?);
    try std.testing.expectEqual(PdkParamId.layer_map,       PARAM_MAP.get("layer_map").?);
    try std.testing.expectEqual(PdkParamId.metal_direction, PARAM_MAP.get("metal_direction").?);
    try std.testing.expectEqual(PdkParamId.layers,          PARAM_MAP.get("layers").?);
    try std.testing.expect(PARAM_MAP.get("nonexistent") == null);
}
