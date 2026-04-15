// ─── TemplateContext ──────────────────────────────────────────────────────────
//
// Wraps a GdsLibrary and extracts the primary user-area cell with its pins,
// ready for use by the placer (hard bounds) and router (blocked regions).
//
// Pin direction is inferred from common power/ground net name conventions.
// All other pins default to .inout — safe for analog signals.

const std = @import("std");
const gdsii = @import("gdsii.zig");

const Allocator = std.mem.Allocator;
const GdsLibrary = gdsii.GdsLibrary;
const GdsCell = gdsii.GdsCell;

// ─── Public types ─────────────────────────────────────────────────────────────

/// Inferred signal direction for a template pin.
pub const TemplatePinDir = enum(u8) {
    input = 0,
    output = 1,
    inout = 2,
    power = 3,
    ground = 4,
};

/// A pin extracted from the template cell, sized for C-ABI compatibility.
pub const TemplatePin = extern struct {
    /// Null-padded pin name (up to 63 significant characters).
    name: [64]u8,
    layer: u16,
    datatype: u16,
    /// Position in microns.
    x: f32,
    y: f32,
    direction: TemplatePinDir,
    _pad: [3]u8 = .{ 0, 0, 0 },
};

/// The main output of loading a GDS template file.
///
/// Holds the full GdsLibrary and exposes the primary user-area cell's
/// bounding box and pin list.
pub const TemplateContext = struct {
    library: GdsLibrary,
    /// Index into library.cells of the identified user-area cell.
    /// Null only if the library is empty or no matching cell was found.
    user_cell_idx: ?usize,
    /// [xmin, ymin, xmax, ymax] in microns — the placeable region.
    user_bbox: [4]f32,
    /// Owned slice of extracted pins.
    pins: []TemplatePin,
    allocator: Allocator,

    // ─── Factory ──────────────────────────────────────────────────────────────

    /// Load a GDS template file and build a TemplateContext.
    ///
    /// If `cell_name` is non-null the named cell is used as the user-area cell.
    /// Otherwise the cell with the largest bounding-box area is selected
    /// (typical for TinyTapeout where the wrapper cell is the largest).
    pub fn loadFromGds(
        path: []const u8,
        cell_name: ?[]const u8,
        allocator: Allocator,
    ) !TemplateContext {
        const library = try gdsii.readFromFile(path, allocator);
        return buildFromLibrary(library, cell_name, allocator);
    }

    /// Variant for unit tests: build from an already-parsed GdsLibrary.
    /// Takes ownership of `library`; caller must not call library.deinit().
    pub fn fromLibrary(
        library: GdsLibrary,
        cell_name: ?[]const u8,
        allocator: Allocator,
    ) !TemplateContext {
        return buildFromLibrary(library, cell_name, allocator);
    }

    // ─── Accessors ────────────────────────────────────────────────────────────

    /// Returns [xmin, ymin, xmax, ymax] in microns.
    pub fn getUserAreaBounds(self: *const TemplateContext) [4]f32 {
        return self.user_bbox;
    }

    /// Returns all extracted template pins.
    pub fn getPins(self: *const TemplateContext) []const TemplatePin {
        return self.pins;
    }

    // ─── Cleanup ──────────────────────────────────────────────────────────────

    pub fn deinit(self: *TemplateContext) void {
        self.allocator.free(self.pins);
        self.library.deinit();
    }
};

// ─── Internal helpers ─────────────────────────────────────────────────────────

/// Core construction logic shared between loadFromGds and fromLibrary.
fn buildFromLibrary(
    library: GdsLibrary,
    cell_name: ?[]const u8,
    allocator: Allocator,
) !TemplateContext {
    // Find the target cell
    var user_cell_idx: ?usize = null;

    if (cell_name) |name| {
        // Explicit name: find by exact match
        for (library.cells, 0..) |*cell, i| {
            if (std.mem.eql(u8, cell.name, name)) {
                user_cell_idx = i;
                break;
            }
        }
    } else {
        // Auto-select: pick the cell with the largest bounding-box area
        var largest_area: f64 = -1.0;
        for (library.cells, 0..) |*cell, i| {
            if (!cell.has_bbox) continue;
            const w = cell.bbox[2] - cell.bbox[0];
            const h = cell.bbox[3] - cell.bbox[1];
            const area = w * h;
            if (area > largest_area) {
                largest_area = area;
                user_cell_idx = i;
            }
        }
    }

    // Build the user bbox from the selected cell (or zeroed if none found)
    var user_bbox: [4]f32 = .{ 0.0, 0.0, 0.0, 0.0 };
    if (user_cell_idx) |idx| {
        const cell = &library.cells[idx];
        if (cell.has_bbox) {
            user_bbox = .{
                @floatCast(cell.bbox[0]),
                @floatCast(cell.bbox[1]),
                @floatCast(cell.bbox[2]),
                @floatCast(cell.bbox[3]),
            };
        }
    }

    // Extract pins from the selected cell
    var pin_list: std.ArrayList(TemplatePin) = .empty;
    errdefer pin_list.deinit(allocator);

    if (user_cell_idx) |idx| {
        const cell = &library.cells[idx];
        try pin_list.ensureTotalCapacity(allocator, cell.pins.len);
        for (cell.pins) |*gds_pin| {
            var tpin = TemplatePin{
                .name = [_]u8{0} ** 64,
                .layer = gds_pin.layer,
                .datatype = gds_pin.datatype,
                .x = @floatCast(gds_pin.x),
                .y = @floatCast(gds_pin.y),
                .direction = inferPinDirection(gds_pin.name),
                ._pad = .{ 0, 0, 0 },
            };
            // Copy name — truncate to 63 chars if needed, always NUL-terminate at [63]
            const copy_len = @min(gds_pin.name.len, 63);
            @memcpy(tpin.name[0..copy_len], gds_pin.name[0..copy_len]);
            pin_list.appendAssumeCapacity(tpin);
        }
    }

    const pins = try pin_list.toOwnedSlice(allocator);

    return TemplateContext{
        .library = library,
        .user_cell_idx = user_cell_idx,
        .user_bbox = user_bbox,
        .pins = pins,
        .allocator = allocator,
    };
}

/// Infer the direction of a pin from its name.
///
/// Power nets:   VDD, VPWR, VCC
/// Ground nets:  VSS, GND, VGND
/// Input hints:  IN, CLK, RST, RESET, *_IN
/// Output hints: OUT, Q, Z, *_OUT
/// All others:   inout (safe conservative default for analog)
fn inferPinDirection(name: []const u8) TemplatePinDir {
    // Case-insensitive compare using a stack buffer
    var upper_buf: [64]u8 = undefined;
    const upper = upperCase(name, &upper_buf);

    if (std.mem.eql(u8, upper, "VDD") or
        std.mem.eql(u8, upper, "VPWR") or
        std.mem.eql(u8, upper, "VCC"))
        return .power;

    if (std.mem.eql(u8, upper, "VSS") or
        std.mem.eql(u8, upper, "GND") or
        std.mem.eql(u8, upper, "VGND"))
        return .ground;

    if (std.mem.endsWith(u8, upper, "_IN") or
        std.mem.eql(u8, upper, "IN") or
        std.mem.eql(u8, upper, "CLK") or
        std.mem.eql(u8, upper, "RST") or
        std.mem.eql(u8, upper, "RESET"))
        return .input;

    if (std.mem.endsWith(u8, upper, "_OUT") or
        std.mem.eql(u8, upper, "OUT") or
        std.mem.eql(u8, upper, "Q") or
        std.mem.eql(u8, upper, "Z"))
        return .output;

    return .inout;
}

/// ASCII-only upper-case conversion into a caller-provided buffer.
/// Returns a slice of `buf` up to `min(name.len, buf.len)`.
fn upperCase(name: []const u8, buf: []u8) []u8 {
    const n = @min(name.len, buf.len);
    for (0..n) |i| {
        buf[i] = std.ascii.toUpper(name[i]);
    }
    return buf[0..n];
}

// ─── Tests ────────────────────────────────────────────────────────────────────

test "inferPinDirection power nets" {
    try std.testing.expectEqual(TemplatePinDir.power, inferPinDirection("VDD"));
    try std.testing.expectEqual(TemplatePinDir.power, inferPinDirection("VPWR"));
    try std.testing.expectEqual(TemplatePinDir.power, inferPinDirection("VCC"));
}

test "inferPinDirection ground nets" {
    try std.testing.expectEqual(TemplatePinDir.ground, inferPinDirection("VSS"));
    try std.testing.expectEqual(TemplatePinDir.ground, inferPinDirection("GND"));
    try std.testing.expectEqual(TemplatePinDir.ground, inferPinDirection("VGND"));
}

test "inferPinDirection input hints" {
    try std.testing.expectEqual(TemplatePinDir.input, inferPinDirection("CLK"));
    try std.testing.expectEqual(TemplatePinDir.input, inferPinDirection("RST"));
    try std.testing.expectEqual(TemplatePinDir.input, inferPinDirection("IN"));
    try std.testing.expectEqual(TemplatePinDir.input, inferPinDirection("DATA_IN"));
}

test "inferPinDirection output hints" {
    try std.testing.expectEqual(TemplatePinDir.output, inferPinDirection("OUT"));
    try std.testing.expectEqual(TemplatePinDir.output, inferPinDirection("Q"));
    try std.testing.expectEqual(TemplatePinDir.output, inferPinDirection("DATA_OUT"));
}

test "inferPinDirection defaults to inout" {
    try std.testing.expectEqual(TemplatePinDir.inout, inferPinDirection("SIGNAL_A"));
    try std.testing.expectEqual(TemplatePinDir.inout, inferPinDirection("ANA_IO"));
    try std.testing.expectEqual(TemplatePinDir.inout, inferPinDirection(""));
}

test "TemplatePin extern struct layout" {
    // 64 + 2 + 2 + 4 + 4 + 1 + 3 = 80 bytes
    try std.testing.expectEqual(@as(usize, 80), @sizeOf(TemplatePin));
    try std.testing.expectEqual(@as(usize, 0),  @offsetOf(TemplatePin, "name"));
    try std.testing.expectEqual(@as(usize, 64), @offsetOf(TemplatePin, "layer"));
    try std.testing.expectEqual(@as(usize, 66), @offsetOf(TemplatePin, "datatype"));
    try std.testing.expectEqual(@as(usize, 68), @offsetOf(TemplatePin, "x"));
    try std.testing.expectEqual(@as(usize, 72), @offsetOf(TemplatePin, "y"));
    try std.testing.expectEqual(@as(usize, 76), @offsetOf(TemplatePin, "direction"));
}

test "TemplateContext from manually constructed library" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const gds_mod = @import("gdsii.zig");

    // Build a GdsLibrary by hand to avoid filesystem dependency
    const pin_name = try allocator.dupe(u8, "VDD");
    const cell_name_str = try allocator.dupe(u8, "WRAPPER");

    const pins_slice = try allocator.alloc(gds_mod.GdsPin, 1);
    pins_slice[0] = gds_mod.GdsPin{
        .name = pin_name,
        .layer = 68,
        .datatype = 20,
        .x = 5.0,
        .y = 10.0,
    };

    const refs_slice = try allocator.alloc(gds_mod.GdsSref, 0);

    const cells_slice = try allocator.alloc(gds_mod.GdsCell, 1);
    cells_slice[0] = gds_mod.GdsCell{
        .name = cell_name_str,
        .bbox = .{ 0.0, 0.0, 160.0, 100.0 },
        .has_bbox = true,
        .pins = pins_slice,
        .refs = refs_slice,
        .polygon_count = 1,
        .path_count = 0,
        .allocator = allocator,
    };

    const lib_name = try allocator.dupe(u8, "testlib");
    const library = gds_mod.GdsLibrary{
        .name = lib_name,
        .db_unit = 1e-9,
        .user_unit = 1e-6,
        .cells = cells_slice,
        .allocator = allocator,
    };

    var ctx = try TemplateContext.fromLibrary(library, "WRAPPER", allocator);
    defer ctx.deinit();

    // Verify bbox
    const bounds = ctx.getUserAreaBounds();
    try std.testing.expectApproxEqRel(@as(f32, 0.0),   bounds[0], 1e-6);
    try std.testing.expectApproxEqRel(@as(f32, 0.0),   bounds[1], 1e-6);
    try std.testing.expectApproxEqRel(@as(f32, 160.0), bounds[2], 1e-6);
    try std.testing.expectApproxEqRel(@as(f32, 100.0), bounds[3], 1e-6);

    // Verify pins
    const out_pins = ctx.getPins();
    try std.testing.expectEqual(@as(usize, 1), out_pins.len);
    try std.testing.expectEqualStrings("VDD", std.mem.sliceTo(&out_pins[0].name, 0));
    try std.testing.expectEqual(TemplatePinDir.power, out_pins[0].direction);
    try std.testing.expectApproxEqRel(@as(f32, 5.0),  out_pins[0].x, 1e-6);
    try std.testing.expectApproxEqRel(@as(f32, 10.0), out_pins[0].y, 1e-6);

    // Verify user_cell_idx
    try std.testing.expectEqual(@as(?usize, 0), ctx.user_cell_idx);
}

test "TemplateContext auto-selects largest cell" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const gds_mod = @import("gdsii.zig");

    // Cell 0: small (10 × 10)
    const small_name  = try allocator.dupe(u8, "SMALL");
    const small_pins  = try allocator.alloc(gds_mod.GdsPin, 0);
    const small_refs  = try allocator.alloc(gds_mod.GdsSref, 0);

    // Cell 1: large (160 × 100)
    const large_name  = try allocator.dupe(u8, "LARGE");
    const large_pins  = try allocator.alloc(gds_mod.GdsPin, 0);
    const large_refs  = try allocator.alloc(gds_mod.GdsSref, 0);

    const cells_slice = try allocator.alloc(gds_mod.GdsCell, 2);
    cells_slice[0] = gds_mod.GdsCell{
        .name = small_name,
        .bbox = .{ 0.0, 0.0, 10.0, 10.0 },
        .has_bbox = true,
        .pins = small_pins,
        .refs = small_refs,
        .polygon_count = 0,
        .path_count = 0,
        .allocator = allocator,
    };
    cells_slice[1] = gds_mod.GdsCell{
        .name = large_name,
        .bbox = .{ 0.0, 0.0, 160.0, 100.0 },
        .has_bbox = true,
        .pins = large_pins,
        .refs = large_refs,
        .polygon_count = 0,
        .path_count = 0,
        .allocator = allocator,
    };

    const lib_name = try allocator.dupe(u8, "multi");
    const library = gds_mod.GdsLibrary{
        .name = lib_name,
        .db_unit = 1e-9,
        .user_unit = 1e-6,
        .cells = cells_slice,
        .allocator = allocator,
    };

    var ctx = try TemplateContext.fromLibrary(library, null, allocator);
    defer ctx.deinit();

    // Should have selected the large cell (index 1)
    try std.testing.expectEqual(@as(?usize, 1), ctx.user_cell_idx);
    const bounds = ctx.getUserAreaBounds();
    try std.testing.expectApproxEqRel(@as(f32, 160.0), bounds[2], 1e-6);
    try std.testing.expectApproxEqRel(@as(f32, 100.0), bounds[3], 1e-6);
}

test "TemplateContext named cell not found returns empty bbox" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const gds_mod = @import("gdsii.zig");

    const cell_name_str = try allocator.dupe(u8, "CELL_A");
    const pins_slice = try allocator.alloc(gds_mod.GdsPin, 0);
    const refs_slice = try allocator.alloc(gds_mod.GdsSref, 0);
    const cells_slice = try allocator.alloc(gds_mod.GdsCell, 1);
    cells_slice[0] = gds_mod.GdsCell{
        .name = cell_name_str,
        .bbox = .{ 0.0, 0.0, 50.0, 50.0 },
        .has_bbox = true,
        .pins = pins_slice,
        .refs = refs_slice,
        .polygon_count = 0,
        .path_count = 0,
        .allocator = allocator,
    };

    const lib_name = try allocator.dupe(u8, "lib");
    const library = gds_mod.GdsLibrary{
        .name = lib_name,
        .db_unit = 1e-9,
        .user_unit = 1e-6,
        .cells = cells_slice,
        .allocator = allocator,
    };

    // Request a cell name that does not exist
    var ctx = try TemplateContext.fromLibrary(library, "NONEXISTENT", allocator);
    defer ctx.deinit();

    try std.testing.expectEqual(@as(?usize, null), ctx.user_cell_idx);
    const bounds = ctx.getUserAreaBounds();
    try std.testing.expectEqual(@as(f32, 0.0), bounds[0]);
    try std.testing.expectEqual(@as(f32, 0.0), bounds[2]);
}
