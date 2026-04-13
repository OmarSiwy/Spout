// liberty/gds_area.zig
//
// Minimal GDSII binary parser for bounding-box extraction.
//
// Reads a GDSII stream file and accumulates the coordinate extents of all
// BOUNDARY and PATH elements to produce a cell bounding box.  Only the
// subset of GDSII records needed for coordinate extraction is handled;
// everything else is skipped.
//
// GDSII binary format reference:
//   Each record: [u16 BE length] [u8 record_type] [u8 data_type] [payload...]
//   XY record (0x10, 0x03): array of i32 BE pairs (x, y) in database units.

const std = @import("std");
const records = @import("../export/records.zig");

const RecordType = records.RecordType;

// ─── Bounding box ───────────────────────────────────────────────────────────

pub const BoundingBox = struct {
    x_min: i64,
    y_min: i64,
    x_max: i64,
    y_max: i64,
    valid: bool,

    pub fn empty() BoundingBox {
        return .{
            .x_min = std.math.maxInt(i64),
            .y_min = std.math.maxInt(i64),
            .x_max = std.math.minInt(i64),
            .y_max = std.math.minInt(i64),
            .valid = false,
        };
    }

    pub fn extend(self: *BoundingBox, x: i32, y: i32) void {
        const xl: i64 = @intCast(x);
        const yl: i64 = @intCast(y);
        if (xl < self.x_min) self.x_min = xl;
        if (xl > self.x_max) self.x_max = xl;
        if (yl < self.y_min) self.y_min = yl;
        if (yl > self.y_max) self.y_max = yl;
        self.valid = true;
    }

    /// Cell area in µm², given the database-unit-to-µm conversion factor.
    pub fn areaUm2(self: BoundingBox) f64 {
        if (!self.valid) return 0.0;
        const w: f64 = @floatFromInt(self.x_max - self.x_min);
        const h: f64 = @floatFromInt(self.y_max - self.y_min);
        // Coordinates are already in database units; caller converts via db_unit_um.
        return w * h;
    }

    /// Width in database units.
    pub fn width(self: BoundingBox) f64 {
        if (!self.valid) return 0.0;
        return @floatFromInt(self.x_max - self.x_min);
    }

    /// Height in database units.
    pub fn height(self: BoundingBox) f64 {
        if (!self.valid) return 0.0;
        return @floatFromInt(self.y_max - self.y_min);
    }
};

// ─── GDS reader ─────────────────────────────────────────────────────────────

pub const GdsReadError = error{
    InvalidHeader,
    UnexpectedEof,
    FileTooSmall,
};

/// Read a GDSII binary file and return the bounding box of all geometry.
/// `db_unit_um` is the database unit in µm (sky130 = 0.001).
/// The returned BoundingBox coordinates are in database units; multiply by
/// db_unit_um to get µm.  The areaUm2() method returns area in db-unit².
/// Caller should multiply by db_unit_um² to get µm².
pub fn readBoundingBox(gds_path: []const u8, db_unit_um: f64) !BoundingBox {
    _ = db_unit_um; // Stored for future use; bbox is in db units.

    const file = std.fs.cwd().openFile(gds_path, .{}) catch |err| {
        return switch (err) {
            error.FileNotFound => GdsReadError.InvalidHeader,
            else => err,
        };
    };
    defer file.close();

    var bbox = BoundingBox.empty();
    var in_element = false;

    while (true) {
        // Read 4-byte record header
        var hdr_buf: [4]u8 = undefined;
        const hdr_read = file.read(&hdr_buf) catch break;
        if (hdr_read < 4) break;

        const rec_len = std.mem.readInt(u16, hdr_buf[0..2], .big);
        const rec_type = hdr_buf[2];
        // const data_type = hdr_buf[3]; // unused

        // Payload length = total - 4 header bytes
        const payload_len: usize = if (rec_len >= 4) rec_len - 4 else 0;

        // Check for BOUNDARY or PATH → we're in a geometry element
        if (rec_type == RecordType.BOUNDARY.recordByte() or
            rec_type == RecordType.PATH.recordByte())
        {
            in_element = true;
        }

        // ENDEL → leaving element
        if (rec_type == RecordType.ENDEL.recordByte()) {
            in_element = false;
        }

        // XY record inside a geometry element → extract coordinates
        if (rec_type == RecordType.XY.recordByte() and in_element and payload_len >= 8) {
            // Read coordinate payload
            const n_coords = payload_len / 4; // number of i32 values
            const n_points = n_coords / 2; // each point is (x, y)

            var i: usize = 0;
            while (i < n_points) : (i += 1) {
                var coord_buf: [4]u8 = undefined;

                const xr = file.read(&coord_buf) catch break;
                if (xr < 4) break;
                const x = std.mem.readInt(i32, &coord_buf, .big);

                const yr = file.read(&coord_buf) catch break;
                if (yr < 4) break;
                const y = std.mem.readInt(i32, &coord_buf, .big);

                bbox.extend(x, y);
            }
            // We already consumed the payload via individual reads
            continue;
        }

        // Skip payload for records we don't parse
        if (payload_len > 0) {
            file.seekBy(@intCast(payload_len)) catch break;
        }

        // ENDLIB → done
        if (rec_type == RecordType.ENDLIB.recordByte()) break;
    }

    return bbox;
}

/// Parse bounding box from an in-memory GDSII byte buffer.
/// Useful for testing without touching the filesystem.
pub fn readBoundingBoxFromMemory(data: []const u8) BoundingBox {
    var bbox = BoundingBox.empty();
    var in_element = false;
    var pos: usize = 0;

    while (pos + 4 <= data.len) {
        const rec_len = std.mem.readInt(u16, data[pos..][0..2], .big);
        const rec_type = data[pos + 2];

        const payload_start = pos + 4;
        const payload_len: usize = if (rec_len >= 4) rec_len - 4 else 0;
        const rec_end = pos + @as(usize, rec_len);
        if (rec_end > data.len) break;

        if (rec_type == RecordType.BOUNDARY.recordByte() or
            rec_type == RecordType.PATH.recordByte())
        {
            in_element = true;
        }

        if (rec_type == RecordType.ENDEL.recordByte()) {
            in_element = false;
        }

        if (rec_type == RecordType.XY.recordByte() and in_element and payload_len >= 8) {
            const n_coords = payload_len / 4;
            const n_points = n_coords / 2;

            var i: usize = 0;
            while (i < n_points) : (i += 1) {
                const off = payload_start + i * 8;
                if (off + 8 > data.len) break;
                const x = std.mem.readInt(i32, data[off..][0..4], .big);
                const y = std.mem.readInt(i32, data[off + 4 ..][0..4], .big);
                bbox.extend(x, y);
            }
        }

        if (rec_type == RecordType.ENDLIB.recordByte()) break;
        pos = rec_end;
    }

    return bbox;
}

// ─── Tests ──────────────────────────────────────────────────────────────────

test "BoundingBox empty" {
    const bbox = BoundingBox.empty();
    try std.testing.expect(!bbox.valid);
    try std.testing.expectEqual(@as(f64, 0.0), bbox.areaUm2());
}

test "BoundingBox extend and area" {
    var bbox = BoundingBox.empty();
    bbox.extend(0, 0);
    bbox.extend(1000, 2000);
    try std.testing.expect(bbox.valid);
    try std.testing.expectEqual(@as(i64, 0), bbox.x_min);
    try std.testing.expectEqual(@as(i64, 0), bbox.y_min);
    try std.testing.expectEqual(@as(i64, 1000), bbox.x_max);
    try std.testing.expectEqual(@as(i64, 2000), bbox.y_max);
    // Area in db units squared: 1000 * 2000 = 2,000,000
    try std.testing.expectEqual(@as(f64, 2_000_000.0), bbox.areaUm2());
}

test "BoundingBox negative coordinates" {
    var bbox = BoundingBox.empty();
    bbox.extend(-500, -300);
    bbox.extend(500, 300);
    try std.testing.expectEqual(@as(f64, 1000.0), bbox.width());
    try std.testing.expectEqual(@as(f64, 600.0), bbox.height());
    try std.testing.expectEqual(@as(f64, 600_000.0), bbox.areaUm2());
}

test "readBoundingBoxFromMemory with synthetic GDSII" {
    // Build a minimal GDSII: HEADER, BGNLIB, BGNSTR, BOUNDARY, XY(4 points), ENDEL, ENDSTR, ENDLIB
    var buf: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const w = fbs.writer();

    // HEADER (version 600)
    try records.writeInt16Record(w, .HEADER, 600);
    // BGNLIB (12 i16 values = 24 bytes of timestamps)
    try records.writeRecord(w, .BGNLIB, &([_]u8{0} ** 24));
    // LIBNAME
    try records.writeStringRecord(w, .LIBNAME, "test");
    // UNITS (two f64 values)
    try records.writeFloat64Record(w, .UNITS, 0.001);
    try records.writeFloat64Record(w, .UNITS, 1.0e-9);
    // BGNSTR
    try records.writeRecord(w, .BGNSTR, &([_]u8{0} ** 24));
    // STRNAME
    try records.writeStringRecord(w, .STRNAME, "cell");
    // BOUNDARY
    try records.writeRecord(w, .BOUNDARY, &[_]u8{});
    // LAYER 0
    try records.writeInt16Record(w, .LAYER, 0);
    // DATATYPE 0
    try records.writeInt16Record(w, .DATATYPE, 0);
    // XY: rectangle (0,0) → (1000, 0) → (1000, 500) → (0, 500) → (0, 0)
    var xy_data: [40]u8 = undefined; // 5 points * 2 coords * 4 bytes
    const points = [_][2]i32{
        .{ 0, 0 },
        .{ 1000, 0 },
        .{ 1000, 500 },
        .{ 0, 500 },
        .{ 0, 0 }, // closing
    };
    for (points, 0..) |pt, i| {
        std.mem.writeInt(i32, xy_data[i * 8 ..][0..4], pt[0], .big);
        std.mem.writeInt(i32, xy_data[i * 8 + 4 ..][0..4], pt[1], .big);
    }
    try records.writeRecord(w, .XY, &xy_data);
    // ENDEL
    try records.writeRecord(w, .ENDEL, &[_]u8{});
    // ENDSTR
    try records.writeRecord(w, .ENDSTR, &[_]u8{});
    // ENDLIB
    try records.writeRecord(w, .ENDLIB, &[_]u8{});

    const written = fbs.getWritten();
    const bbox = readBoundingBoxFromMemory(written);

    try std.testing.expect(bbox.valid);
    try std.testing.expectEqual(@as(i64, 0), bbox.x_min);
    try std.testing.expectEqual(@as(i64, 0), bbox.y_min);
    try std.testing.expectEqual(@as(i64, 1000), bbox.x_max);
    try std.testing.expectEqual(@as(i64, 500), bbox.y_max);
    // Area = 1000 * 500 = 500,000 db-units²
    try std.testing.expectEqual(@as(f64, 500_000.0), bbox.areaUm2());
}
