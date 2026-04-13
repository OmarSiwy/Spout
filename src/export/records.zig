const std = @import("std");

// ─── GDSII Record Type Definitions ──────────────────────────────────────────
//
// Each GDSII record begins with a 4-byte header:
//   [2 bytes: total record length] [1 byte: record type] [1 byte: data type]
//
// The record type encodes both the kind (high byte) and data type (low byte)
// in the GDSII specification. Here we define the full 16-bit combined value
// per the standard, as well as writer functions that encode records in
// big-endian binary format.

pub const RecordType = enum(u16) {
    HEADER = 0x0002,
    BGNLIB = 0x0102,
    LIBNAME = 0x0206,
    UNITS = 0x0305,
    ENDLIB = 0x0400,
    BGNSTR = 0x0502,
    STRNAME = 0x0606,
    ENDSTR = 0x0700,
    BOUNDARY = 0x0800,
    PATH = 0x0900,
    ENDEL = 0x1100,
    LAYER = 0x0D02,
    DATATYPE = 0x0E02,
    XY = 0x1003,
    PATHTYPE = 0x2102,
    WIDTH = 0x0F03,
    TEXT = 0x0C00,
    TEXTTYPE = 0x1602,
    STRING = 0x1906,

    /// Extract the record-type byte (high byte of the combined value).
    pub fn recordByte(self: RecordType) u8 {
        return @intCast(@intFromEnum(self) >> 8);
    }

    /// Extract the data-type byte (low byte of the combined value).
    pub fn dataByte(self: RecordType) u8 {
        return @truncate(@intFromEnum(self));
    }
};

// ─── Writer functions ───────────────────────────────────────────────────────
//
// These write binary GDSII records to any std.io writer.
// The format for each record is:
//   [u16 big-endian: total_length] [u8: record_type] [u8: data_type] [payload...]
//
// total_length includes the 4-byte header.

/// Write a raw GDSII record with an arbitrary byte payload.
/// This is the lowest-level writer; all other write*Record functions call this.
pub fn writeRecord(writer: anytype, rec: RecordType, data: []const u8) !void {
    const total_len: u16 = @intCast(4 + data.len);
    // Write length as big-endian u16.
    const len_bytes = std.mem.toBytes(std.mem.nativeTo(u16, total_len, .big));
    try writer.writeAll(&len_bytes);
    // Write record type and data type bytes.
    try writer.writeByte(rec.recordByte());
    try writer.writeByte(rec.dataByte());
    // Write payload.
    try writer.writeAll(data);
}

/// Write a record containing a single 16-bit signed integer value.
pub fn writeInt16Record(writer: anytype, rec: RecordType, value: i16) !void {
    const bytes = std.mem.toBytes(std.mem.nativeTo(i16, value, .big));
    try writeRecord(writer, rec, &bytes);
}

/// Write a record containing a single 32-bit signed integer value.
pub fn writeInt32Record(writer: anytype, rec: RecordType, value: i32) !void {
    const bytes = std.mem.toBytes(std.mem.nativeTo(i32, value, .big));
    try writeRecord(writer, rec, &bytes);
}

/// Write a record containing a 64-bit floating-point value.
///
/// GDSII uses its own 8-byte real format (not IEEE 754). This function
/// converts an IEEE 754 f64 to the GDSII excess-64 base-16 representation.
pub fn writeFloat64Record(writer: anytype, rec: RecordType, value: f64) !void {
    var buf: [8]u8 = toGdsiiReal(value);
    try writeRecord(writer, rec, &buf);
}

/// Write a record containing an ASCII string.
///
/// GDSII strings must be padded to an even number of bytes. If the string
/// length is odd, a null byte is appended.
pub fn writeStringRecord(writer: anytype, rec: RecordType, text: []const u8) !void {
    const padded_len = (text.len + 1) & ~@as(usize, 1); // round up to even
    const total_len: u16 = @intCast(4 + padded_len);

    const len_bytes = std.mem.toBytes(std.mem.nativeTo(u16, total_len, .big));
    try writer.writeAll(&len_bytes);
    try writer.writeByte(rec.recordByte());
    try writer.writeByte(rec.dataByte());
    try writer.writeAll(text);
    if (padded_len > text.len) {
        try writer.writeByte(0); // pad byte
    }
}

// ─── GDSII real number conversion ───────────────────────────────────────────
//
// GDSII uses an excess-64, base-16, 8-byte floating point format:
//   Bit 63:     sign (0 = positive, 1 = negative)
//   Bits 62-56: exponent + 64 (excess-64, base 16)
//   Bits 55-0:  mantissa (56-bit fraction, normalised so that the leading
//               hex digit is non-zero)
//
// Value = (-1)^sign * mantissa * 16^(exponent - 64)

pub fn toGdsiiReal(value: f64) [8]u8 {
    if (value == 0.0) return .{ 0, 0, 0, 0, 0, 0, 0, 0 };

    var v = value;
    var sign_byte: u8 = 0;
    if (v < 0.0) {
        sign_byte = 0x80;
        v = -v;
    }

    // Determine the base-16 exponent.
    // We want: v = mantissa * 16^exp, where 1/16 <= mantissa < 1.
    var exp: i32 = 0;
    while (v >= 1.0) {
        v /= 16.0;
        exp += 1;
    }
    while (v < 1.0 / 16.0) {
        v *= 16.0;
        exp -= 1;
    }

    // The mantissa occupies 56 bits (7 bytes).
    const mantissa: u64 = @intFromFloat(v * @as(f64, @floatFromInt(@as(u64, 1) << 56)));

    const biased_exp: u8 = @intCast(@as(i32, 64) + exp);

    var result: [8]u8 = undefined;
    result[0] = sign_byte | biased_exp;
    result[1] = @truncate(mantissa >> 48);
    result[2] = @truncate(mantissa >> 40);
    result[3] = @truncate(mantissa >> 32);
    result[4] = @truncate(mantissa >> 24);
    result[5] = @truncate(mantissa >> 16);
    result[6] = @truncate(mantissa >> 8);
    result[7] = @truncate(mantissa);

    return result;
}

/// Convert a GDSII excess-64 base-16 real back to an IEEE 754 f64.
/// Useful for testing round-trip accuracy.
pub fn fromGdsiiReal(bytes: [8]u8) f64 {
    const sign: f64 = if (bytes[0] & 0x80 != 0) -1.0 else 1.0;
    const biased_exp: i32 = @intCast(bytes[0] & 0x7F);
    const exp = biased_exp - 64;

    var mantissa: u64 = 0;
    for (1..8) |i| {
        mantissa = (mantissa << 8) | @as(u64, bytes[i]);
    }

    const frac: f64 = @as(f64, @floatFromInt(mantissa)) / @as(f64, @floatFromInt(@as(u64, 1) << 56));
    return sign * frac * std.math.pow(f64, 16.0, @floatFromInt(exp));
}

// ─── Tests ──────────────────────────────────────────────────────────────────

test "RecordType enum values" {
    try std.testing.expectEqual(@as(u16, 0x0002), @intFromEnum(RecordType.HEADER));
    try std.testing.expectEqual(@as(u16, 0x0102), @intFromEnum(RecordType.BGNLIB));
    try std.testing.expectEqual(@as(u16, 0x0206), @intFromEnum(RecordType.LIBNAME));
    try std.testing.expectEqual(@as(u16, 0x0400), @intFromEnum(RecordType.ENDLIB));
    try std.testing.expectEqual(@as(u16, 0x0800), @intFromEnum(RecordType.BOUNDARY));
    try std.testing.expectEqual(@as(u16, 0x0900), @intFromEnum(RecordType.PATH));
    try std.testing.expectEqual(@as(u16, 0x1100), @intFromEnum(RecordType.ENDEL));
    try std.testing.expectEqual(@as(u16, 0x1003), @intFromEnum(RecordType.XY));
    try std.testing.expectEqual(@as(u16, 0x0F03), @intFromEnum(RecordType.WIDTH));
    try std.testing.expectEqual(@as(u16, 0x0C00), @intFromEnum(RecordType.TEXT));
    try std.testing.expectEqual(@as(u16, 0x1602), @intFromEnum(RecordType.TEXTTYPE));
    try std.testing.expectEqual(@as(u16, 0x1906), @intFromEnum(RecordType.STRING));
}

test "RecordType recordByte and dataByte" {
    try std.testing.expectEqual(@as(u8, 0x00), RecordType.HEADER.recordByte());
    try std.testing.expectEqual(@as(u8, 0x02), RecordType.HEADER.dataByte());

    try std.testing.expectEqual(@as(u8, 0x0D), RecordType.LAYER.recordByte());
    try std.testing.expectEqual(@as(u8, 0x02), RecordType.LAYER.dataByte());

    try std.testing.expectEqual(@as(u8, 0x10), RecordType.XY.recordByte());
    try std.testing.expectEqual(@as(u8, 0x03), RecordType.XY.dataByte());
}

test "writeRecord produces correct binary" {
    var buf: [64]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    var writer = fbs.writer();

    // Write an ENDLIB record (no payload).
    try writeRecord(&writer, RecordType.ENDLIB, &[_]u8{});

    const written = fbs.getWritten();
    // Total length = 4 (header only), big-endian.
    try std.testing.expectEqual(@as(u8, 0x00), written[0]);
    try std.testing.expectEqual(@as(u8, 0x04), written[1]);
    // Record type = 0x04, data type = 0x00.
    try std.testing.expectEqual(@as(u8, 0x04), written[2]);
    try std.testing.expectEqual(@as(u8, 0x00), written[3]);
    try std.testing.expectEqual(@as(usize, 4), written.len);
}

test "writeInt16Record produces correct binary" {
    var buf: [64]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    var writer = fbs.writer();

    try writeInt16Record(&writer, RecordType.LAYER, 5);

    const written = fbs.getWritten();
    // Length = 4 + 2 = 6.
    try std.testing.expectEqual(@as(u8, 0x00), written[0]);
    try std.testing.expectEqual(@as(u8, 0x06), written[1]);
    // Record type = 0x0D, data type = 0x02.
    try std.testing.expectEqual(@as(u8, 0x0D), written[2]);
    try std.testing.expectEqual(@as(u8, 0x02), written[3]);
    // Value 5 as big-endian i16.
    try std.testing.expectEqual(@as(u8, 0x00), written[4]);
    try std.testing.expectEqual(@as(u8, 0x05), written[5]);
}

test "writeInt32Record produces correct binary" {
    var buf: [64]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    var writer = fbs.writer();

    try writeInt32Record(&writer, RecordType.WIDTH, 1000);

    const written = fbs.getWritten();
    // Length = 4 + 4 = 8.
    try std.testing.expectEqual(@as(u8, 0x00), written[0]);
    try std.testing.expectEqual(@as(u8, 0x08), written[1]);
    // Record type = 0x0F, data type = 0x03.
    try std.testing.expectEqual(@as(u8, 0x0F), written[2]);
    try std.testing.expectEqual(@as(u8, 0x03), written[3]);
    // Value 1000 = 0x000003E8 as big-endian i32.
    try std.testing.expectEqual(@as(u8, 0x00), written[4]);
    try std.testing.expectEqual(@as(u8, 0x00), written[5]);
    try std.testing.expectEqual(@as(u8, 0x03), written[6]);
    try std.testing.expectEqual(@as(u8, 0xE8), written[7]);
}

test "writeStringRecord pads odd-length strings" {
    var buf: [64]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    var writer = fbs.writer();

    // "TOP" has length 3 (odd) → padded to 4.
    try writeStringRecord(&writer, RecordType.STRNAME, "TOP");

    const written = fbs.getWritten();
    // Length = 4 + 4 = 8 (3 chars + 1 pad).
    try std.testing.expectEqual(@as(u8, 0x00), written[0]);
    try std.testing.expectEqual(@as(u8, 0x08), written[1]);
    // Record type = 0x06, data type = 0x06.
    try std.testing.expectEqual(@as(u8, 0x06), written[2]);
    try std.testing.expectEqual(@as(u8, 0x06), written[3]);
    // "TOP" + null pad.
    try std.testing.expectEqual(@as(u8, 'T'), written[4]);
    try std.testing.expectEqual(@as(u8, 'O'), written[5]);
    try std.testing.expectEqual(@as(u8, 'P'), written[6]);
    try std.testing.expectEqual(@as(u8, 0x00), written[7]);
}

test "writeStringRecord even-length string no pad" {
    var buf: [64]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    var writer = fbs.writer();

    // "CELL" has length 4 (even) → no padding needed.
    try writeStringRecord(&writer, RecordType.LIBNAME, "CELL");

    const written = fbs.getWritten();
    // Length = 4 + 4 = 8.
    try std.testing.expectEqual(@as(u8, 0x00), written[0]);
    try std.testing.expectEqual(@as(u8, 0x08), written[1]);
    try std.testing.expectEqual(@as(usize, 8), written.len);
}

test "GDSII real round-trip for 1e-3" {
    const original: f64 = 1.0e-3;
    const gdsii_bytes = toGdsiiReal(original);
    const recovered = fromGdsiiReal(gdsii_bytes);
    try std.testing.expectApproxEqRel(original, recovered, 1e-9);
}

test "GDSII real round-trip for 1e-9" {
    const original: f64 = 1.0e-9;
    const gdsii_bytes = toGdsiiReal(original);
    const recovered = fromGdsiiReal(gdsii_bytes);
    try std.testing.expectApproxEqRel(original, recovered, 1e-9);
}

test "GDSII real zero" {
    const gdsii_bytes = toGdsiiReal(0.0);
    for (gdsii_bytes) |b| {
        try std.testing.expectEqual(@as(u8, 0), b);
    }
    try std.testing.expectEqual(@as(f64, 0.0), fromGdsiiReal(gdsii_bytes));
}

test "GDSII real negative value" {
    const original: f64 = -42.5;
    const gdsii_bytes = toGdsiiReal(original);
    // Sign bit should be set.
    try std.testing.expect(gdsii_bytes[0] & 0x80 != 0);
    const recovered = fromGdsiiReal(gdsii_bytes);
    try std.testing.expectApproxEqRel(original, recovered, 1e-9);
}
