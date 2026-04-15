// ─── GDSII Binary Reader ─────────────────────────────────────────────────────
//
// Reads a GDSII stream file into a structured GdsLibrary.
//
// GDSII binary format (each record):
//   [u16 big-endian: total_length]  (includes 4-byte header)
//   [u8: record_type]
//   [u8: data_type]
//   [payload...]
//
// Data type codes:
//   0x00 = no data
//   0x02 = u16 array (big-endian)
//   0x03 = i32 array (big-endian)
//   0x05 = GDSII real (8-byte excess-64 base-16)
//   0x06 = ASCII string

const std = @import("std");
const Allocator = std.mem.Allocator;

// ─── Record type codes ────────────────────────────────────────────────────────

const RT_HEADER   : u16 = 0x0002;
const RT_BGNLIB   : u16 = 0x0102;
const RT_LIBNAME  : u16 = 0x0206;
const RT_UNITS    : u16 = 0x0305;
const RT_ENDLIB   : u16 = 0x0400;
const RT_BGNSTR   : u16 = 0x0502;
const RT_STRNAME  : u16 = 0x0606;
const RT_ENDSTR   : u16 = 0x0700;
const RT_BOUNDARY : u16 = 0x0800;
const RT_PATH     : u16 = 0x0900;
const RT_SREF     : u16 = 0x0A00;
const RT_AREF     : u16 = 0x0B00;
const RT_TEXT     : u16 = 0x0C00;
const RT_LAYER    : u16 = 0x0D02;
const RT_DATATYPE : u16 = 0x0E02;
const RT_WIDTH    : u16 = 0x0F03;
const RT_XY       : u16 = 0x1003;
const RT_ENDEL    : u16 = 0x1100;
const RT_SNAME    : u16 = 0x1206;
const RT_TEXTTYPE : u16 = 0x1602;
const RT_STRING   : u16 = 0x1906;
const RT_STRANS   : u16 = 0x1A02;
const RT_AMAG     : u16 = 0x1B05;
const RT_AANGLE   : u16 = 0x1C05;

// ─── Public types ─────────────────────────────────────────────────────────────

/// A TEXT-label pin extracted from a GDS cell.
pub const GdsPin = struct {
    /// Owned by this GdsPin — free with allocator.free(name).
    name: []const u8,
    layer: u16,
    datatype: u16,
    /// Position in microns.
    x: f64,
    y: f64,
};

/// A structure reference (SREF) — a placed instance of another cell.
pub const GdsSref = struct {
    /// Owned by this GdsSref — free with allocator.free(cell_name).
    cell_name: []const u8,
    /// Placement origin in microns.
    x: f64,
    y: f64,
    /// Rotation in degrees.
    angle: f64,
    /// Magnification factor (1.0 = no scaling).
    magnification: f64,
    /// Mirror about the X axis before rotation.
    mirror_x: bool,
};

/// All geometry and sub-structure data extracted from one GDSII cell (structure).
pub const GdsCell = struct {
    /// Owned — free with allocator.free(name).
    name: []const u8,
    /// [xmin, ymin, xmax, ymax] in microns.  Only valid when has_bbox is true.
    bbox: [4]f64,
    /// False if the cell contains no geometry (no BOUNDARY/PATH/TEXT elements).
    has_bbox: bool,
    /// TEXT labels interpreted as pin declarations.  Owned slice.
    pins: []GdsPin,
    /// Sub-cell references.  Owned slice.
    refs: []GdsSref,
    /// Count of BOUNDARY elements parsed.
    polygon_count: u32,
    /// Count of PATH elements parsed.
    path_count: u32,
    allocator: Allocator,

    /// Free all memory owned by this cell.
    pub fn deinit(self: *GdsCell) void {
        self.allocator.free(self.name);
        for (self.pins) |*pin| {
            self.allocator.free(pin.name);
        }
        self.allocator.free(self.pins);
        for (self.refs) |*ref| {
            self.allocator.free(ref.cell_name);
        }
        self.allocator.free(self.refs);
    }
};

/// The top-level result of parsing a GDSII file.
pub const GdsLibrary = struct {
    /// Owned — free with allocator.free(name).
    name: []const u8,
    /// Meters per database unit (e.g. 1e-9 for sky130).
    db_unit: f64,
    /// Meters per user unit (e.g. 1e-6 = 1 µm).
    user_unit: f64,
    /// All parsed cells.  Owned slice.
    cells: []GdsCell,
    allocator: Allocator,

    /// Find a cell by name.  Returns null if not found.
    pub fn findCell(self: *const GdsLibrary, name: []const u8) ?*const GdsCell {
        for (self.cells) |*cell| {
            if (std.mem.eql(u8, cell.name, name)) return cell;
        }
        return null;
    }

    /// Free all memory owned by this library.
    pub fn deinit(self: *GdsLibrary) void {
        self.allocator.free(self.name);
        for (self.cells) |*cell| {
            cell.deinit();
        }
        self.allocator.free(self.cells);
    }
};

// ─── Public entry points ──────────────────────────────────────────────────────

/// Read a GDSII file from disk.
pub fn readFromFile(path: []const u8, allocator: Allocator) !GdsLibrary {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    const data = try file.readToEndAlloc(allocator, 256 * 1024 * 1024); // 256 MiB max
    defer allocator.free(data);
    return readFromBytes(data, allocator);
}

/// Read a GDSII library from an in-memory byte slice.
pub fn readFromBytes(data: []const u8, allocator: Allocator) !GdsLibrary {
    var parser = Parser.init(data, allocator);
    return parser.parse();
}

// ─── GDSII real conversion ────────────────────────────────────────────────────

/// Convert an 8-byte GDSII excess-64 base-16 real to IEEE 754 f64.
fn gdsRealToF64(bytes: [8]u8) f64 {
    if (bytes[0] == 0 and bytes[1] == 0 and bytes[2] == 0 and
        bytes[3] == 0 and bytes[4] == 0 and bytes[5] == 0 and
        bytes[6] == 0 and bytes[7] == 0) return 0.0;

    const sign: f64 = if (bytes[0] & 0x80 != 0) -1.0 else 1.0;
    const biased_exp: i32 = @intCast(bytes[0] & 0x7F);
    const exp: i32 = biased_exp - 64;

    var mantissa: u64 = 0;
    for (1..8) |i| {
        mantissa = (mantissa << 8) | @as(u64, bytes[i]);
    }

    // mantissa is a 56-bit integer representing a fraction: frac = mantissa / 2^56
    const frac: f64 = @as(f64, @floatFromInt(mantissa)) /
        @as(f64, @floatFromInt(@as(u64, 1) << 56));
    return sign * frac * std.math.pow(f64, 16.0, @floatFromInt(exp));
}

// ─── Parser internals ─────────────────────────────────────────────────────────

/// Element-level state machine states.
const ElemState = enum {
    idle,
    in_boundary,
    in_path,
    in_sref,
    in_text,
    in_aref,
};

/// In-progress SREF being built.
const SrefBuilder = struct {
    cell_name: ?[]const u8 = null, // owned copy
    x: f64 = 0.0,
    y: f64 = 0.0,
    angle: f64 = 0.0,
    magnification: f64 = 1.0,
    mirror_x: bool = false,
};

/// In-progress TEXT/pin being built.
const PinBuilder = struct {
    text: ?[]const u8 = null, // owned copy
    layer: u16 = 0,
    datatype: u16 = 0,
    x: f64 = 0.0,
    y: f64 = 0.0,
};

/// Parser holds all mutable state needed during streaming.
/// Uses std.ArrayList (managed — stores allocator internally).
const Parser = struct {
    data: []const u8,
    pos: usize,
    allocator: Allocator,

    // Library-level state
    lib_name: []const u8,
    db_unit: f64,
    user_unit: f64,
    cells: std.ArrayList(GdsCell),

    // Cell-level state
    in_cell: bool,
    cell_name: ?[]const u8, // owned copy, consumed at ENDSTR
    cell_bbox: [4]f64,
    cell_has_bbox: bool,
    cell_pins: std.ArrayList(GdsPin),
    cell_refs: std.ArrayList(GdsSref),
    cell_polygon_count: u32,
    cell_path_count: u32,

    // Element-level state
    elem_state: ElemState,
    cur_layer: u16,
    cur_datatype: u16,
    cur_width: i32,
    cur_xy: std.ArrayList([2]i32), // raw db-unit coordinate pairs

    // Pending builders
    sref_builder: SrefBuilder,
    pin_builder: PinBuilder,

    fn init(data: []const u8, allocator: Allocator) Parser {
        return .{
            .data = data,
            .pos = 0,
            .allocator = allocator,
            .lib_name = &[_]u8{},
            .db_unit = 1e-9,
            .user_unit = 1e-6,
            .cells = .empty,
            .in_cell = false,
            .cell_name = null,
            .cell_bbox = .{ 0, 0, 0, 0 },
            .cell_has_bbox = false,
            .cell_pins = .empty,
            .cell_refs = .empty,
            .cell_polygon_count = 0,
            .cell_path_count = 0,
            .elem_state = .idle,
            .cur_layer = 0,
            .cur_datatype = 0,
            .cur_width = 0,
            .cur_xy = .empty,
            .sref_builder = .{},
            .pin_builder = .{},
        };
    }

    fn deinitOnError(self: *Parser) void {
        // Free the lib name if we allocated it
        if (self.lib_name.len > 0) self.allocator.free(self.lib_name);
        // Free cells allocated so far
        for (self.cells.items) |*cell| cell.deinit();
        self.cells.deinit(self.allocator);
        // Free cell-level state
        if (self.cell_name) |n| self.allocator.free(n);
        for (self.cell_pins.items) |*pin| self.allocator.free(pin.name);
        self.cell_pins.deinit(self.allocator);
        for (self.cell_refs.items) |*ref| self.allocator.free(ref.cell_name);
        self.cell_refs.deinit(self.allocator);
        self.cur_xy.deinit(self.allocator);
        // Free any pending sref/pin strings
        if (self.sref_builder.cell_name) |n| self.allocator.free(n);
        if (self.pin_builder.text) |t| self.allocator.free(t);
    }

    /// Convert database-unit integer to microns.
    fn toUm(self: *const Parser, db_coord: i32) f64 {
        const db: f64 = @floatFromInt(db_coord);
        return db * (self.db_unit / 1e-6);
    }

    /// Expand bounding box to include a point in microns.
    fn expandBbox(self: *Parser, x_um: f64, y_um: f64) void {
        if (!self.cell_has_bbox) {
            self.cell_bbox = .{ x_um, y_um, x_um, y_um };
            self.cell_has_bbox = true;
        } else {
            if (x_um < self.cell_bbox[0]) self.cell_bbox[0] = x_um;
            if (y_um < self.cell_bbox[1]) self.cell_bbox[1] = y_um;
            if (x_um > self.cell_bbox[2]) self.cell_bbox[2] = x_um;
            if (y_um > self.cell_bbox[3]) self.cell_bbox[3] = y_um;
        }
    }

    /// Read a GDSII record header and return (record_code, payload_slice).
    /// The payload slice references self.data directly (no allocation).
    fn readRecord(self: *Parser) !?struct { code: u16, payload: []const u8 } {
        if (self.pos >= self.data.len) return null;
        if (self.pos + 4 > self.data.len) return error.TruncatedRecord;

        const hdr = self.data[self.pos .. self.pos + 4];
        const total_len = std.mem.readInt(u16, hdr[0..2], .big);
        if (total_len < 4) return error.InvalidRecordLength;

        const record_type: u8 = hdr[2];
        const data_type: u8 = hdr[3];
        const code: u16 = (@as(u16, record_type) << 8) | @as(u16, data_type);
        const payload_len: usize = total_len - 4;

        self.pos += 4;
        if (self.pos + payload_len > self.data.len) return error.TruncatedPayload;
        const payload = self.data[self.pos .. self.pos + payload_len];
        self.pos += payload_len;

        return .{ .code = code, .payload = payload };
    }

    /// Parse payload as a string (ASCII, possibly NUL-padded), dupe into allocator.
    fn payloadAsString(self: *Parser, payload: []const u8) ![]const u8 {
        // Trim trailing NUL bytes
        var end = payload.len;
        while (end > 0 and payload[end - 1] == 0) end -= 1;
        return self.allocator.dupe(u8, payload[0..end]);
    }

    /// Parse a GDSII real from payload at given byte offset (8 bytes).
    fn payloadAsReal(payload: []const u8, offset: usize) !f64 {
        if (offset + 8 > payload.len) return error.PayloadTooShort;
        var buf: [8]u8 = undefined;
        @memcpy(&buf, payload[offset .. offset + 8]);
        return gdsRealToF64(buf);
    }

    /// Parse payload as a u16 (big-endian, first two bytes).
    fn payloadAsU16(payload: []const u8) !u16 {
        if (payload.len < 2) return error.PayloadTooShort;
        return std.mem.readInt(u16, payload[0..2], .big);
    }

    /// Parse payload as an i32 (big-endian, first four bytes).
    fn payloadAsI32(payload: []const u8) !i32 {
        if (payload.len < 4) return error.PayloadTooShort;
        return std.mem.readInt(i32, payload[0..4], .big);
    }

    /// Process XY payload: store coordinate pairs and update bbox per element type.
    fn processXY(self: *Parser, payload: []const u8) !void {
        if (payload.len % 4 != 0) return error.MisalignedPayload;
        const count = payload.len / 4;
        const pairs = count / 2;

        self.cur_xy.clearRetainingCapacity();
        try self.cur_xy.ensureTotalCapacity(self.allocator, pairs);

        var i: usize = 0;
        while (i < pairs) : (i += 1) {
            const x = std.mem.readInt(i32, payload[8 * i ..][0..4], .big);
            const y = std.mem.readInt(i32, payload[8 * i + 4 ..][0..4], .big);
            self.cur_xy.appendAssumeCapacity(.{ x, y });
        }

        // Update bounding box based on current element type
        switch (self.elem_state) {
            .in_boundary => {
                for (self.cur_xy.items) |pt| {
                    self.expandBbox(self.toUm(pt[0]), self.toUm(pt[1]));
                }
            },
            .in_path => {
                const half_w: f64 = self.toUm(@divTrunc(self.cur_width, 2));
                for (self.cur_xy.items) |pt| {
                    const x = self.toUm(pt[0]);
                    const y = self.toUm(pt[1]);
                    self.expandBbox(x - half_w, y - half_w);
                    self.expandBbox(x + half_w, y + half_w);
                }
            },
            .in_text => {
                if (self.cur_xy.items.len > 0) {
                    const pt = self.cur_xy.items[0];
                    const x = self.toUm(pt[0]);
                    const y = self.toUm(pt[1]);
                    self.expandBbox(x, y);
                    self.pin_builder.x = x;
                    self.pin_builder.y = y;
                }
            },
            .in_sref => {
                if (self.cur_xy.items.len > 0) {
                    const pt = self.cur_xy.items[0];
                    self.sref_builder.x = self.toUm(pt[0]);
                    self.sref_builder.y = self.toUm(pt[1]);
                }
            },
            .in_aref, .idle => {
                // AREF: skip; idle: harmless
            },
        }
    }

    /// Finalize the current element and reset element-level state.
    fn finalizeElement(self: *Parser) !void {
        switch (self.elem_state) {
            .in_boundary => {
                self.cell_polygon_count += 1;
            },
            .in_path => {
                self.cell_path_count += 1;
            },
            .in_sref => {
                const builder = self.sref_builder;
                const cell_name = builder.cell_name orelse
                    try self.allocator.dupe(u8, "");
                const ref = GdsSref{
                    .cell_name = cell_name,
                    .x = builder.x,
                    .y = builder.y,
                    .angle = builder.angle,
                    .magnification = builder.magnification,
                    .mirror_x = builder.mirror_x,
                };
                try self.cell_refs.append(self.allocator, ref);
                self.sref_builder = .{};
            },
            .in_text => {
                const builder = self.pin_builder;
                const pin_name = builder.text orelse
                    try self.allocator.dupe(u8, "");
                const pin = GdsPin{
                    .name = pin_name,
                    .layer = builder.layer,
                    .datatype = builder.datatype,
                    .x = builder.x,
                    .y = builder.y,
                };
                try self.cell_pins.append(self.allocator, pin);
                self.pin_builder = .{};
            },
            .in_aref => {
                // AREF: not parsed in detail
            },
            .idle => {},
        }
        self.elem_state = .idle;
        self.cur_xy.clearRetainingCapacity();
    }

    /// Reset cell-level state for a new structure.
    fn beginCell(self: *Parser) void {
        self.in_cell = true;
        self.cell_name = null;
        self.cell_bbox = .{ 0, 0, 0, 0 };
        self.cell_has_bbox = false;
        self.cell_polygon_count = 0;
        self.cell_path_count = 0;
        self.elem_state = .idle;
        self.cell_pins.clearRetainingCapacity();
        self.cell_refs.clearRetainingCapacity();
    }

    /// Commit the current cell to the cells list.
    fn endCell(self: *Parser) !void {
        if (!self.in_cell) return;
        self.in_cell = false;

        const name = self.cell_name orelse
            try self.allocator.dupe(u8, "");
        self.cell_name = null;

        const pins = try self.cell_pins.toOwnedSlice(self.allocator);
        const refs = try self.cell_refs.toOwnedSlice(self.allocator);

        const cell = GdsCell{
            .name = name,
            .bbox = self.cell_bbox,
            .has_bbox = self.cell_has_bbox,
            .pins = pins,
            .refs = refs,
            .polygon_count = self.cell_polygon_count,
            .path_count = self.cell_path_count,
            .allocator = self.allocator,
        };
        try self.cells.append(self.allocator, cell);
    }

    /// Main parsing loop.
    pub fn parse(self: *Parser) !GdsLibrary {
        errdefer self.deinitOnError();

        while (try self.readRecord()) |rec| {
            switch (rec.code) {
                RT_HEADER => {
                    // Skip version number
                },
                RT_BGNLIB => {
                    // Skip library timestamp
                },
                RT_LIBNAME => {
                    if (self.lib_name.len > 0) self.allocator.free(self.lib_name);
                    self.lib_name = try self.payloadAsString(rec.payload);
                },
                RT_UNITS => {
                    // First 8 bytes: user unit in meters/user-unit
                    // Next 8 bytes: db unit in meters/db-unit
                    if (rec.payload.len >= 16) {
                        self.user_unit = try payloadAsReal(rec.payload, 0);
                        self.db_unit = try payloadAsReal(rec.payload, 8);
                    }
                },
                RT_BGNSTR => {
                    self.beginCell();
                },
                RT_STRNAME => {
                    if (self.cell_name) |old| self.allocator.free(old);
                    self.cell_name = try self.payloadAsString(rec.payload);
                },
                RT_BOUNDARY => {
                    self.elem_state = .in_boundary;
                    self.cur_layer = 0;
                    self.cur_datatype = 0;
                },
                RT_PATH => {
                    self.elem_state = .in_path;
                    self.cur_layer = 0;
                    self.cur_datatype = 0;
                    self.cur_width = 0;
                },
                RT_SREF => {
                    self.elem_state = .in_sref;
                    self.sref_builder = .{};
                },
                RT_AREF => {
                    self.elem_state = .in_aref;
                },
                RT_TEXT => {
                    self.elem_state = .in_text;
                    self.pin_builder = .{};
                    self.cur_layer = 0;
                    self.cur_datatype = 0;
                },
                RT_LAYER => {
                    const layer = try payloadAsU16(rec.payload);
                    self.cur_layer = layer;
                    switch (self.elem_state) {
                        .in_text => self.pin_builder.layer = layer,
                        else => {},
                    }
                },
                RT_DATATYPE => {
                    const dt = try payloadAsU16(rec.payload);
                    self.cur_datatype = dt;
                    switch (self.elem_state) {
                        .in_text => self.pin_builder.datatype = dt,
                        else => {},
                    }
                },
                RT_TEXTTYPE => {
                    // Same semantics as DATATYPE for TEXT elements
                    const dt = try payloadAsU16(rec.payload);
                    switch (self.elem_state) {
                        .in_text => self.pin_builder.datatype = dt,
                        else => {},
                    }
                },
                RT_WIDTH => {
                    self.cur_width = try payloadAsI32(rec.payload);
                },
                RT_XY => {
                    try self.processXY(rec.payload);
                },
                RT_SNAME => {
                    if (self.elem_state == .in_sref) {
                        if (self.sref_builder.cell_name) |old| self.allocator.free(old);
                        self.sref_builder.cell_name = try self.payloadAsString(rec.payload);
                    }
                },
                RT_STRING => {
                    if (self.elem_state == .in_text) {
                        if (self.pin_builder.text) |old| self.allocator.free(old);
                        self.pin_builder.text = try self.payloadAsString(rec.payload);
                    }
                },
                RT_STRANS => {
                    if (rec.payload.len >= 2) {
                        const flags = std.mem.readInt(u16, rec.payload[0..2], .big);
                        if (self.elem_state == .in_sref) {
                            self.sref_builder.mirror_x = (flags & 0x8000) != 0;
                        }
                    }
                },
                RT_AMAG => {
                    if (rec.payload.len >= 8) {
                        const mag = try payloadAsReal(rec.payload, 0);
                        if (self.elem_state == .in_sref) {
                            self.sref_builder.magnification = mag;
                        }
                    }
                },
                RT_AANGLE => {
                    if (rec.payload.len >= 8) {
                        const angle = try payloadAsReal(rec.payload, 0);
                        if (self.elem_state == .in_sref) {
                            self.sref_builder.angle = angle;
                        }
                    }
                },
                RT_ENDEL => {
                    try self.finalizeElement();
                },
                RT_ENDSTR => {
                    try self.endCell();
                },
                RT_ENDLIB => {
                    break;
                },
                else => {
                    // Unknown or unhandled record — payload already consumed
                },
            }
        }

        const cells = try self.cells.toOwnedSlice(self.allocator);

        // lib_name ownership transfers to GdsLibrary
        const lib_name = if (self.lib_name.len > 0)
            self.lib_name
        else
            try self.allocator.dupe(u8, "");
        // Zero out lib_name so deinitOnError won't double-free
        self.lib_name = &[_]u8{};

        // Deinit now-empty ArrayLists
        self.cells.deinit(self.allocator);
        self.cell_pins.deinit(self.allocator);
        self.cell_refs.deinit(self.allocator);
        self.cur_xy.deinit(self.allocator);

        return GdsLibrary{
            .name = lib_name,
            .db_unit = self.db_unit,
            .user_unit = self.user_unit,
            .cells = cells,
            .allocator = self.allocator,
        };
    }
};

// ─── Test helpers ─────────────────────────────────────────────────────────────

/// Encode a GDSII real value for test stream construction.
fn encodeGdsReal(val: f64) [8]u8 {
    if (val == 0.0) return [_]u8{0} ** 8;
    var v = val;
    var sign_byte: u8 = 0;
    if (v < 0.0) { sign_byte = 0x80; v = -v; }
    var exp: i32 = 0;
    while (v >= 1.0) { v /= 16.0; exp += 1; }
    while (v < 1.0 / 16.0) { v *= 16.0; exp -= 1; }
    const m: u64 = @intFromFloat(v * @as(f64, @floatFromInt(@as(u64, 1) << 56)));
    const be: u8 = @intCast(@as(i32, 64) + exp);
    return .{
        sign_byte | be,
        @truncate(m >> 48), @truncate(m >> 40), @truncate(m >> 32),
        @truncate(m >> 24), @truncate(m >> 16), @truncate(m >> 8),
        @truncate(m),
    };
}

/// Write a raw GDSII record (code + payload) into an ArrayList(u8).
fn writeTestRecord(allocator: Allocator, buf: *std.ArrayList(u8), code: u16, payload: []const u8) !void {
    const total: u16 = @intCast(4 + payload.len);
    var hdr: [4]u8 = undefined;
    std.mem.writeInt(u16, hdr[0..2], total, .big);
    hdr[2] = @intCast(code >> 8);
    hdr[3] = @truncate(code);
    try buf.appendSlice(allocator, &hdr);
    try buf.appendSlice(allocator, payload);
}

/// Write a string record (even-padded) into an ArrayList(u8).
fn writeTestStringRecord(allocator: Allocator, buf: *std.ArrayList(u8), code: u16, s: []const u8) !void {
    const padded = (s.len + 1) & ~@as(usize, 1);
    const total: u16 = @intCast(4 + padded);
    var hdr: [4]u8 = undefined;
    std.mem.writeInt(u16, hdr[0..2], total, .big);
    hdr[2] = @intCast(code >> 8);
    hdr[3] = @truncate(code);
    try buf.appendSlice(allocator, &hdr);
    try buf.appendSlice(allocator, s);
    if (padded > s.len) try buf.append(allocator, 0);
}

/// Build a minimal complete GDSII byte stream for unit tests.
fn buildTestGds(allocator: Allocator) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    // HEADER version=5
    try writeTestRecord(allocator, &buf, RT_HEADER, &[_]u8{ 0, 5 });
    // BGNLIB (24 bytes of zeroed i16 timestamps)
    try writeTestRecord(allocator, &buf, RT_BGNLIB, &([_]u8{0} ** 24));
    // LIBNAME "testlib"
    try writeTestStringRecord(allocator, &buf, RT_LIBNAME, "testlib");
    // UNITS: user_unit=1e-6, db_unit=1e-9
    var units_payload: [16]u8 = undefined;
    @memcpy(units_payload[0..8], &encodeGdsReal(1e-6));
    @memcpy(units_payload[8..16], &encodeGdsReal(1e-9));
    try writeTestRecord(allocator, &buf, RT_UNITS, &units_payload);

    // BGNSTR + STRNAME
    try writeTestRecord(allocator, &buf, RT_BGNSTR, &([_]u8{0} ** 24));
    try writeTestStringRecord(allocator, &buf, RT_STRNAME, "TOPCELL");

    // BOUNDARY element: rectangle (0,0)→(1000,500) in db units (nm)
    try writeTestRecord(allocator, &buf, RT_BOUNDARY, &[_]u8{});
    try writeTestRecord(allocator, &buf, RT_LAYER,    &[_]u8{ 0, 68 });
    try writeTestRecord(allocator, &buf, RT_DATATYPE, &[_]u8{ 0, 20 });
    var xy_payload: [40]u8 = undefined;
    const pts = [_][2]i32{ .{0,0}, .{1000,0}, .{1000,500}, .{0,500}, .{0,0} };
    for (pts, 0..) |pt, i| {
        std.mem.writeInt(i32, xy_payload[8*i..][0..4], pt[0], .big);
        std.mem.writeInt(i32, xy_payload[8*i+4..][0..4], pt[1], .big);
    }
    try writeTestRecord(allocator, &buf, RT_XY,   &xy_payload);
    try writeTestRecord(allocator, &buf, RT_ENDEL, &[_]u8{});

    // TEXT element (pin label "VDD" at 500,250 nm)
    try writeTestRecord(allocator, &buf, RT_TEXT,     &[_]u8{});
    try writeTestRecord(allocator, &buf, RT_LAYER,    &[_]u8{ 0, 83 });
    try writeTestRecord(allocator, &buf, RT_TEXTTYPE, &[_]u8{ 0, 44 });
    var text_xy: [8]u8 = undefined;
    std.mem.writeInt(i32, text_xy[0..4], 500, .big);
    std.mem.writeInt(i32, text_xy[4..8], 250, .big);
    try writeTestRecord(allocator, &buf, RT_XY, &text_xy);
    try writeTestStringRecord(allocator, &buf, RT_STRING, "VDD");
    try writeTestRecord(allocator, &buf, RT_ENDEL, &[_]u8{});

    // SREF to "SUBCELL" at (200, 300) nm
    try writeTestRecord(allocator, &buf, RT_SREF, &[_]u8{});
    try writeTestStringRecord(allocator, &buf, RT_SNAME, "SUBCELL");
    var sref_xy: [8]u8 = undefined;
    std.mem.writeInt(i32, sref_xy[0..4], 200, .big);
    std.mem.writeInt(i32, sref_xy[4..8], 300, .big);
    try writeTestRecord(allocator, &buf, RT_XY,   &sref_xy);
    try writeTestRecord(allocator, &buf, RT_ENDEL, &[_]u8{});

    // ENDSTR + ENDLIB
    try writeTestRecord(allocator, &buf, RT_ENDSTR, &[_]u8{});
    try writeTestRecord(allocator, &buf, RT_ENDLIB, &[_]u8{});

    return buf.toOwnedSlice(allocator);
}

// ─── Tests ────────────────────────────────────────────────────────────────────

test "gdsRealToF64 zero" {
    const bytes = [8]u8{ 0, 0, 0, 0, 0, 0, 0, 0 };
    try std.testing.expectEqual(@as(f64, 0.0), gdsRealToF64(bytes));
}

test "gdsRealToF64 round-trip 1e-6" {
    const val: f64 = 1.0e-6;
    const encoded = encodeGdsReal(val);
    const recovered = gdsRealToF64(encoded);
    try std.testing.expectApproxEqRel(val, recovered, 1e-9);
}

test "gdsRealToF64 round-trip 1e-9" {
    const val: f64 = 1.0e-9;
    const encoded = encodeGdsReal(val);
    const recovered = gdsRealToF64(encoded);
    try std.testing.expectApproxEqRel(val, recovered, 1e-9);
}

test "readFromBytes parses minimal GDS" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const data = try buildTestGds(allocator);
    defer allocator.free(data);

    var lib = try readFromBytes(data, allocator);
    defer lib.deinit();

    try std.testing.expectEqualStrings("testlib", lib.name);
    try std.testing.expectApproxEqRel(@as(f64, 1e-9), lib.db_unit, 1e-9);
    try std.testing.expectApproxEqRel(@as(f64, 1e-6), lib.user_unit, 1e-9);
    try std.testing.expectEqual(@as(usize, 1), lib.cells.len);

    const cell = &lib.cells[0];
    try std.testing.expectEqualStrings("TOPCELL", cell.name);
    try std.testing.expect(cell.has_bbox);
    try std.testing.expectEqual(@as(u32, 1), cell.polygon_count);

    // bbox: boundary 0-1000nm × 0-500nm → 0.0-1.0µm × 0.0-0.5µm (db_unit=1e-9)
    try std.testing.expectApproxEqRel(@as(f64, 0.0), cell.bbox[0], 1e-9);
    try std.testing.expectApproxEqRel(@as(f64, 0.0), cell.bbox[1], 1e-9);
    try std.testing.expectApproxEqRel(@as(f64, 1.0), cell.bbox[2], 1e-9);
    try std.testing.expectApproxEqRel(@as(f64, 0.5), cell.bbox[3], 1e-9);

    // Pin: VDD at (500,250)nm = (0.5, 0.25)µm, layer=83
    try std.testing.expectEqual(@as(usize, 1), cell.pins.len);
    try std.testing.expectEqualStrings("VDD", cell.pins[0].name);
    try std.testing.expectEqual(@as(u16, 83), cell.pins[0].layer);
    try std.testing.expectApproxEqRel(@as(f64, 0.5),  cell.pins[0].x, 1e-9);
    try std.testing.expectApproxEqRel(@as(f64, 0.25), cell.pins[0].y, 1e-9);

    // SREF: SUBCELL at (200,300)nm = (0.2, 0.3)µm
    try std.testing.expectEqual(@as(usize, 1), cell.refs.len);
    try std.testing.expectEqualStrings("SUBCELL", cell.refs[0].cell_name);
    try std.testing.expectApproxEqRel(@as(f64, 0.2), cell.refs[0].x, 1e-9);
    try std.testing.expectApproxEqRel(@as(f64, 0.3), cell.refs[0].y, 1e-9);
    try std.testing.expectEqual(false, cell.refs[0].mirror_x);
    try std.testing.expectApproxEqRel(@as(f64, 1.0), cell.refs[0].magnification, 1e-9);
}

test "findCell returns correct cell and null for missing" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const data = try buildTestGds(allocator);
    defer allocator.free(data);

    var lib = try readFromBytes(data, allocator);
    defer lib.deinit();

    const found = lib.findCell("TOPCELL");
    try std.testing.expect(found != null);
    try std.testing.expectEqualStrings("TOPCELL", found.?.name);

    const missing = lib.findCell("DOESNOTEXIST");
    try std.testing.expect(missing == null);
}

test "AREF element does not crash parser" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);

    try writeTestRecord(allocator, &buf, RT_HEADER, &[_]u8{ 0, 5 });
    try writeTestRecord(allocator, &buf, RT_BGNLIB, &([_]u8{0} ** 24));
    try writeTestStringRecord(allocator, &buf, RT_LIBNAME, "areflib");
    var up: [16]u8 = undefined;
    @memcpy(up[0..8],  &encodeGdsReal(1e-6));
    @memcpy(up[8..16], &encodeGdsReal(1e-9));
    try writeTestRecord(allocator, &buf, RT_UNITS, &up);
    try writeTestRecord(allocator, &buf, RT_BGNSTR, &([_]u8{0} ** 24));
    try writeTestStringRecord(allocator, &buf, RT_STRNAME, "CELL");
    // AREF element (we parse but skip)
    try writeTestRecord(allocator, &buf, RT_AREF, &[_]u8{});
    try writeTestStringRecord(allocator, &buf, RT_SNAME, "CHILD");
    // XY: 3 pairs (AREF uses origin + col-delta + row-delta)
    try writeTestRecord(allocator, &buf, RT_XY, &([_]u8{0} ** 24));
    try writeTestRecord(allocator, &buf, RT_ENDEL, &[_]u8{});
    try writeTestRecord(allocator, &buf, RT_ENDSTR, &[_]u8{});
    try writeTestRecord(allocator, &buf, RT_ENDLIB, &[_]u8{});

    const data = try buf.toOwnedSlice(allocator);
    defer allocator.free(data);

    var lib = try readFromBytes(data, allocator);
    defer lib.deinit();

    try std.testing.expectEqualStrings("areflib", lib.name);
    try std.testing.expectEqual(@as(usize, 1), lib.cells.len);
    // AREF does not produce a ref in cell.refs (only SREF does)
    try std.testing.expectEqual(@as(usize, 0), lib.cells[0].refs.len);
}

test "SREF with STRANS mirror_x set" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);

    try writeTestRecord(allocator, &buf, RT_HEADER, &[_]u8{ 0, 5 });
    try writeTestRecord(allocator, &buf, RT_BGNLIB, &([_]u8{0} ** 24));
    try writeTestStringRecord(allocator, &buf, RT_LIBNAME, "stranslib");
    var up: [16]u8 = undefined;
    @memcpy(up[0..8],  &encodeGdsReal(1e-6));
    @memcpy(up[8..16], &encodeGdsReal(1e-9));
    try writeTestRecord(allocator, &buf, RT_UNITS, &up);
    try writeTestRecord(allocator, &buf, RT_BGNSTR, &([_]u8{0} ** 24));
    try writeTestStringRecord(allocator, &buf, RT_STRNAME, "TOP");
    // SREF with STRANS bit 15 set (mirror_x)
    try writeTestRecord(allocator, &buf, RT_SREF, &[_]u8{});
    try writeTestStringRecord(allocator, &buf, RT_SNAME, "SUB");
    // STRANS = 0x8000 (bit 15 = mirror_x)
    try writeTestRecord(allocator, &buf, RT_STRANS, &[_]u8{ 0x80, 0x00 });
    var sxy: [8]u8 = undefined;
    std.mem.writeInt(i32, sxy[0..4], 0, .big);
    std.mem.writeInt(i32, sxy[4..8], 0, .big);
    try writeTestRecord(allocator, &buf, RT_XY, &sxy);
    try writeTestRecord(allocator, &buf, RT_ENDEL, &[_]u8{});
    try writeTestRecord(allocator, &buf, RT_ENDSTR, &[_]u8{});
    try writeTestRecord(allocator, &buf, RT_ENDLIB, &[_]u8{});

    const data = try buf.toOwnedSlice(allocator);
    defer allocator.free(data);

    var lib = try readFromBytes(data, allocator);
    defer lib.deinit();

    try std.testing.expectEqual(@as(usize, 1), lib.cells[0].refs.len);
    try std.testing.expectEqual(true, lib.cells[0].refs[0].mirror_x);
    try std.testing.expectEqualStrings("SUB", lib.cells[0].refs[0].cell_name);
}
