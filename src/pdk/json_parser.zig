/// JSON-based PDK configuration parser.
///
/// Parses a JSON byte slice into a PdkConfig struct.  The JSON schema
/// mirrors the fields of PdkConfig exactly.  Unknown fields are ignored.
/// Missing array elements are zero-padded to length 8.
const std = @import("std");
const layout_if = @import("../core/layout_if.zig");
const types = @import("../core/types.zig");

pub const PdkConfig = layout_if.PdkConfig;
pub const MetalDirection = layout_if.MetalDirection;
pub const LayerTable = layout_if.LayerTable;
pub const GdsLayer = layout_if.GdsLayer;

/// Parse a JSON byte slice into a PdkConfig.
///
/// The `name` field in JSON maps to `id` via the PdkId enum.  Unknown
/// names default to `sky130` (index 0) rather than failing hard, since
/// the enum value is not semantically used at runtime beyond bookkeeping.
///
/// The `allocator` is only used internally for the JSON tokeniser's
/// scratch allocations; the returned PdkConfig owns no heap memory.
pub fn parseCustomPdk(json_bytes: []const u8, allocator: std.mem.Allocator) !PdkConfig {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_bytes, .{});
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return error.InvalidJsonRoot;

    var cfg = std.mem.zeroes(PdkConfig);
    cfg.param_to_um = 1.0e6;
    cfg.guard_ring_width = 0.34;
    cfg.guard_ring_spacing = 0.34;
    cfg.metal_direction = .{.horizontal} ** 8;
    cfg.metal_direction[1] = .vertical; // M2
    cfg.metal_direction[3] = .vertical; // M4
    cfg.metal_direction[5] = .vertical;
    cfg.metal_direction[7] = .vertical;

    // ── name -> id ──────────────────────────────────────────────────────────
    if (root.object.get("name")) |v| {
        if (v == .string) {
            const name = v.string;
            if (std.mem.eql(u8, name, "sky130")) {
                cfg.id = .sky130;
            } else if (std.mem.eql(u8, name, "gf180")) {
                cfg.id = .gf180;
            } else if (std.mem.eql(u8, name, "ihp130")) {
                cfg.id = .ihp130;
            } else {
                cfg.id = .sky130; // default fallback
            }
        }
    }

    // ── scalar fields ───────────────────────────────────────────────────────
    cfg.num_metal_layers = readU8(root, "num_metal_layers") orelse 0;
    cfg.db_unit = readF32(root, "db_unit") orelse 0.0;
    cfg.param_to_um = readF32(root, "param_to_um") orelse cfg.param_to_um;
    cfg.tile_size = readF32(root, "tile_size") orelse 1.0;
    cfg.guard_ring_width = readF32(root, "guard_ring_width") orelse cfg.guard_ring_width;
    cfg.guard_ring_spacing = readF32(root, "guard_ring_spacing") orelse cfg.guard_ring_spacing;
    cfg.li_min_spacing = readF32(root, "li_min_spacing") orelse 0.0;
    cfg.li_min_width = readF32(root, "li_min_width") orelse 0.0;
    cfg.li_min_area = readF32(root, "li_min_area") orelse 0.0;

    // ── f32 arrays of length 8 ──────────────────────────────────────────────
    cfg.min_spacing = readF32Array8(root, "min_spacing");
    cfg.same_net_spacing = readF32Array8(root, "same_net_spacing");
    cfg.min_width = readF32Array8(root, "min_width");
    cfg.via_width = readF32Array8(root, "via_width");
    cfg.min_enclosure = readF32Array8(root, "min_enclosure");
    cfg.min_area = readF32Array8(root, "min_area");
    cfg.metal_pitch = readF32Array8(root, "metal_pitch");
    cfg.metal_thickness = readF32Array8(root, "metal_thickness");
    cfg.j_max = readF32Array8(root, "j_max");

    // ── aux_rules array ─────────────────────────────────────────────────────
    if (root.object.get("aux_rules")) |av| {
        if (av == .array) {
            const arr = av.array.items;
            const n: u8 = @intCast(@min(arr.len, 24));
            for (0..n) |i| {
                if (arr[i] != .object) continue;
                const r = arr[i];
                cfg.aux_rules[i] = .{
                    .gds_layer    = readU16(r, "gds_layer") orelse 0,
                    .gds_datatype = readU16(r, "gds_datatype") orelse 0,
                    .min_width    = readF32(r, "min_width") orelse 0.0,
                    .min_spacing  = readF32(r, "min_spacing") orelse 0.0,
                    .min_area     = readF32(r, "min_area") orelse 0.0,
                };
            }
            cfg.num_aux_rules = n;
        }
    }

    // ── enc_rules array ─────────────────────────────────────────────────────
    if (root.object.get("enc_rules")) |ev| {
        if (ev == .array) {
            const arr = ev.array.items;
            const n: u8 = @intCast(@min(arr.len, 16));
            for (0..n) |i| {
                if (arr[i] != .object) continue;
                const r = arr[i];
                cfg.enc_rules[i] = .{
                    .outer_layer    = readU16(r, "outer_layer") orelse 0,
                    .outer_datatype = readU16(r, "outer_datatype") orelse 0,
                    .inner_layer    = readU16(r, "inner_layer") orelse 0,
                    .inner_datatype = readU16(r, "inner_datatype") orelse 0,
                    .enclosure      = readF32(r, "enclosure") orelse 0.0,
                };
            }
            cfg.num_enc_rules = n;
        }
    }

    // ── cross_rules array ──────────────────────────────────────────────────
    if (root.object.get("cross_rules")) |cv| {
        if (cv == .array) {
            const arr = cv.array.items;
            const n: u8 = @intCast(@min(arr.len, 16));
            for (0..n) |i| {
                if (arr[i] != .object) continue;
                const r = arr[i];
                cfg.cross_rules[i] = .{
                    .layer_a     = readU16(r, "layer_a") orelse 0,
                    .datatype_a  = readU16(r, "datatype_a") orelse 0,
                    .layer_b     = readU16(r, "layer_b") orelse 0,
                    .datatype_b  = readU16(r, "datatype_b") orelse 0,
                    .min_spacing = readF32(r, "min_spacing") orelse 0.0,
                };
            }
            cfg.num_cross_rules = n;
        }
    }

    // ── PEX f32 arrays of length 8 ─────────────────────────────────────────
    cfg.via_resistance = readF32Array8(root, "via_resistance");
    cfg.fringe_cap = readF32Array8(root, "fringe_cap");
    cfg.substrate_cap = readF32Array8(root, "substrate_cap");

    // ── u16 array of length 8 ───────────────────────────────────────────────
    cfg.layer_map = readU16Array8(root, "layer_map");

    // ── optional metal_direction array ──────────────────────────────────────
    if (root.object.get("metal_direction")) |md| {
        if (md == .array) {
            const arr = md.array.items;
            const n = @min(arr.len, 8);
            for (0..n) |i| {
                if (arr[i] == .string) {
                    if (std.mem.eql(u8, arr[i].string, "vertical") or
                        std.mem.eql(u8, arr[i].string, "v"))
                    {
                        cfg.metal_direction[i] = .vertical;
                    } else {
                        cfg.metal_direction[i] = .horizontal;
                    }
                } else if (arr[i] == .integer) {
                    cfg.metal_direction[i] = if (arr[i].integer == 1) .vertical else .horizontal;
                }
            }
        }
    }

    // ── LayerTable ──────────────────────────────────────────────────────────
    if (root.object.get("layers")) |lv| {
        if (lv == .object) {
            cfg.layers = parseLayerTable(lv);
        }
    }

    return cfg;
}

// ── Helpers ─────────────────────────────────────────────────────────────────

fn readF32(obj: std.json.Value, key: []const u8) ?f32 {
    const v = obj.object.get(key) orelse return null;
    return switch (v) {
        .float => @floatCast(v.float),
        .integer => @floatFromInt(v.integer),
        else => null,
    };
}

fn readU8(obj: std.json.Value, key: []const u8) ?u8 {
    const v = obj.object.get(key) orelse return null;
    return switch (v) {
        .integer => @intCast(v.integer),
        else => null,
    };
}

fn readU16(obj: std.json.Value, key: []const u8) ?u16 {
    const v = obj.object.get(key) orelse return null;
    return switch (v) {
        .integer => @intCast(v.integer),
        else => null,
    };
}

fn readF32Array8(obj: std.json.Value, key: []const u8) [8]f32 {
    var out = [_]f32{0.0} ** 8;
    const v = obj.object.get(key) orelse return out;
    if (v != .array) return out;
    const arr = v.array.items;
    const n = @min(arr.len, 8);
    for (0..n) |i| {
        out[i] = switch (arr[i]) {
            .float => @floatCast(arr[i].float),
            .integer => @floatFromInt(arr[i].integer),
            else => 0.0,
        };
    }
    return out;
}

fn readU16Array8(obj: std.json.Value, key: []const u8) [8]u16 {
    var out = [_]u16{0} ** 8;
    const v = obj.object.get(key) orelse return out;
    if (v != .array) return out;
    const arr = v.array.items;
    const n = @min(arr.len, 8);
    for (0..n) |i| {
        out[i] = switch (arr[i]) {
            .integer => @intCast(arr[i].integer),
            else => 0,
        };
    }
    return out;
}

fn isZeroArray(values: [8]f32) bool {
    for (values) |value| {
        if (value != 0.0) return false;
    }
    return true;
}

fn readGdsLayer(v: std.json.Value) GdsLayer {
    if (v != .array) return .{ .layer = 0, .datatype = 0 };
    const arr = v.array.items;
    if (arr.len < 2) return .{ .layer = 0, .datatype = 0 };
    const layer: u16 = switch (arr[0]) {
        .integer => @intCast(arr[0].integer),
        else => 0,
    };
    const datatype: u16 = switch (arr[1]) {
        .integer => @intCast(arr[1].integer),
        else => 0,
    };
    return .{ .layer = layer, .datatype = datatype };
}

fn parseLayerTable(lv: std.json.Value) LayerTable {
    var lt = std.mem.zeroes(LayerTable);
    if (lv != .object) return lt;

    if (lv.object.get("nwell")) |v| lt.nwell = readGdsLayer(v);
    if (lv.object.get("diff")) |v| lt.diff = readGdsLayer(v);
    if (lv.object.get("tap")) |v| lt.tap = readGdsLayer(v);
    if (lv.object.get("poly")) |v| lt.poly = readGdsLayer(v);
    if (lv.object.get("nsdm")) |v| lt.nsdm = readGdsLayer(v);
    if (lv.object.get("psdm")) |v| lt.psdm = readGdsLayer(v);
    if (lv.object.get("npc")) |v| lt.npc = readGdsLayer(v);
    if (lv.object.get("licon")) |v| lt.licon = readGdsLayer(v);
    if (lv.object.get("li")) |v| lt.li = readGdsLayer(v);
    if (lv.object.get("mcon")) |v| lt.mcon = readGdsLayer(v);
    if (lv.object.get("li_pin")) |v| lt.li_pin = readGdsLayer(v);

    if (lv.object.get("metal")) |mv| {
        if (mv == .array) {
            const arr = mv.array.items;
            const n = @min(arr.len, 5);
            for (0..n) |i| {
                lt.metal[i] = readGdsLayer(arr[i]);
            }
        }
    }

    if (lv.object.get("via")) |vv| {
        if (vv == .array) {
            const arr = vv.array.items;
            const n = @min(arr.len, 4);
            for (0..n) |i| {
                lt.via[i] = readGdsLayer(arr[i]);
            }
        }
    }

    if (lv.object.get("metal_pin")) |mpv| {
        if (mpv == .array) {
            const arr = mpv.array.items;
            const n = @min(arr.len, 5);
            for (0..n) |i| {
                lt.metal_pin[i] = readGdsLayer(arr[i]);
            }
        }
    }

    return lt;
}

// ── Tests ────────────────────────────────────────────────────────────────────

test "parseCustomPdk sky130" {
    const json =
        \\{
        \\  "name": "sky130",
        \\  "num_metal_layers": 5,
        \\  "db_unit": 0.001,
        \\  "param_to_um": 1000000.0,
        \\  "tile_size": 1.0,
        \\  "min_spacing": [0.14, 0.14, 0.30, 0.30, 0.80, 0.0, 0.0, 0.0],
        \\  "min_width": [0.14, 0.14, 0.30, 0.30, 1.60, 0.0, 0.0, 0.0],
        \\  "via_width": [0.15, 0.15, 0.20, 0.20, 0.0, 0.0, 0.0, 0.0],
        \\  "min_enclosure": [0.04, 0.04, 0.06, 0.06, 0.08, 0.0, 0.0, 0.0],
        \\  "metal_pitch": [0.34, 0.34, 0.68, 0.68, 3.40, 0.0, 0.0, 0.0],
        \\  "metal_thickness": [0.36, 0.36, 0.36, 0.845, 1.26, 0.0, 0.0, 0.0],
        \\  "j_max": [1.11, 1.11, 1.11, 2.61, 3.91, 0.0, 0.0, 0.0],
        \\  "layer_map": [68, 69, 70, 71, 72, 0, 0, 0],
        \\  "layers": {
        \\    "nwell": [64, 20], "diff": [65, 20], "tap": [65, 44],
        \\    "poly": [66, 20], "nsdm": [93, 44], "psdm": [94, 20],
        \\    "npc": [95, 20], "licon": [66, 44], "li": [67, 20],
        \\    "mcon": [67, 44],
        \\    "metal": [[68,20],[69,20],[70,20],[71,20],[72,20]],
        \\    "via": [[68,44],[69,44],[70,44],[71,44]],
        \\    "li_pin": [67, 5],
        \\    "metal_pin": [[68,5],[69,5],[70,5],[71,5],[72,5]]
        \\  }
        \\}
    ;
    const allocator = std.testing.allocator;
    const cfg = try parseCustomPdk(json, allocator);

    try std.testing.expectEqual(types.PdkId.sky130, cfg.id);
    try std.testing.expectEqual(@as(u8, 5), cfg.num_metal_layers);
    try std.testing.expectApproxEqAbs(@as(f32, 0.001), cfg.db_unit, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.14), cfg.min_spacing[0], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.14), cfg.min_width[0], 1e-6);
    try std.testing.expectEqual(@as(u16, 68), cfg.layer_map[0]);
    try std.testing.expectEqual(@as(u16, 64), cfg.layers.nwell.layer);
    try std.testing.expectEqual(@as(u16, 20), cfg.layers.nwell.datatype);
    try std.testing.expectEqual(@as(u16, 68), cfg.layers.metal[0].layer);
    try std.testing.expectApproxEqAbs(@as(f32, 0.34), cfg.guard_ring_width, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.34), cfg.guard_ring_spacing, 1e-6);
}

test "parseCustomPdk unknown name defaults to sky130" {
    const json =
        \\{"name": "tsmc28", "num_metal_layers": 8, "db_unit": 0.001,
        \\ "param_to_um": 1e6, "tile_size": 1.0,
        \\ "min_spacing":[0.0,0.0,0.0,0.0,0.0,0.0,0.0,0.0],
        \\ "min_width":[0.0,0.0,0.0,0.0,0.0,0.0,0.0,0.0],
        \\ "via_width":[0.0,0.0,0.0,0.0,0.0,0.0,0.0,0.0],
        \\ "min_enclosure":[0.0,0.0,0.0,0.0,0.0,0.0,0.0,0.0],
        \\ "metal_pitch":[0.0,0.0,0.0,0.0,0.0,0.0,0.0,0.0],
        \\ "metal_thickness":[0.0,0.0,0.0,0.0,0.0,0.0,0.0,0.0],
        \\ "j_max":[0.0,0.0,0.0,0.0,0.0,0.0,0.0,0.0],
        \\ "layer_map":[0,0,0,0,0,0,0,0],
        \\ "layers":{"nwell":[0,0],"diff":[0,0],"tap":[0,0],"poly":[0,0],
        \\   "nsdm":[0,0],"psdm":[0,0],"npc":[0,0],"licon":[0,0],
        \\   "li":[0,0],"mcon":[0,0],
        \\   "metal":[[0,0],[0,0],[0,0],[0,0],[0,0]],
        \\   "via":[[0,0],[0,0],[0,0],[0,0]],
        \\   "li_pin":[0,0],"metal_pin":[[0,0],[0,0],[0,0],[0,0],[0,0]]}}
    ;
    const allocator = std.testing.allocator;
    const cfg = try parseCustomPdk(json, allocator);
    try std.testing.expectEqual(types.PdkId.sky130, cfg.id);
    try std.testing.expectEqual(@as(u8, 8), cfg.num_metal_layers);
    try std.testing.expectApproxEqAbs(@as(f32, 0.34), cfg.guard_ring_width, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.34), cfg.guard_ring_spacing, 1e-6);
}

test "parseCustomPdk accepts explicit guard ring values" {
    const json =
        \\{
        \\  "name": "gf180",
        \\  "num_metal_layers": 5,
        \\  "db_unit": 0.001,
        \\  "param_to_um": 1000000.0,
        \\  "tile_size": 1.0,
        \\  "min_spacing": [0.23,0.23,0.28,0.28,0.44,0,0,0],
        \\  "min_width": [0.23,0.23,0.28,0.28,0.44,0,0,0],
        \\  "via_width": [0.26,0.26,0.26,0.26,0,0,0,0],
        \\  "min_enclosure": [0.05,0.05,0.06,0.06,0.09,0,0,0],
        \\  "metal_pitch": [0.56,0.56,0.64,0.64,1.12,0,0,0],
        \\  "metal_thickness": [0.5,0.5,0.9,0.9,1.2,0,0,0],
        \\  "j_max": [1.2,1.2,2,2,3,0,0,0],
        \\  "layer_map": [34,36,42,46,81,0,0,0],
        \\  "guard_ring_width": 0.38,
        \\  "guard_ring_spacing": 0.38
        \\}
    ;
    const allocator = std.testing.allocator;
    const cfg = try parseCustomPdk(json, allocator);
    try std.testing.expectEqual(types.PdkId.gf180, cfg.id);
    try std.testing.expectApproxEqAbs(@as(f32, 0.38), cfg.guard_ring_width, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.38), cfg.guard_ring_spacing, 1e-6);
}
