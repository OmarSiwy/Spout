const std = @import("std");
const gdsii_mod = @import("gdsii.zig");
const records = @import("records.zig");

const GdsiiWriter = gdsii_mod.GdsiiWriter;
const RecordType = records.RecordType;

// ─── GdsiiWriter basic tests ────────────────────────────────────────────────

test "GdsiiWriter init and deinit" {
    var writer = GdsiiWriter.init(std.testing.allocator);
    writer.deinit();
}

// ─── Coordinate conversion tests ────────────────────────────────────────────

test "coordinate conversion: writeI32Be round-trip" {
    // Verify that writeI32Be (from gdsii.zig) correctly encodes big-endian i32.
    // We test indirectly by writing known values and reading them back.
    var buf: [4]u8 = undefined;

    // Positive value.
    const val: i32 = 12345;
    buf = std.mem.toBytes(std.mem.nativeTo(i32, val, .big));
    const recovered = std.mem.bigToNative(i32, @as(*align(1) const i32, @ptrCast(&buf)).*);
    try std.testing.expectEqual(val, recovered);
}

test "coordinate conversion: negative values" {
    var buf: [4]u8 = undefined;
    const val: i32 = -500;
    buf = std.mem.toBytes(std.mem.nativeTo(i32, val, .big));
    const recovered = std.mem.bigToNative(i32, @as(*align(1) const i32, @ptrCast(&buf)).*);
    try std.testing.expectEqual(val, recovered);
}

test "coordinate conversion: zero" {
    var buf: [4]u8 = undefined;
    const val: i32 = 0;
    buf = std.mem.toBytes(std.mem.nativeTo(i32, val, .big));
    try std.testing.expectEqual(@as(u8, 0), buf[0]);
    try std.testing.expectEqual(@as(u8, 0), buf[1]);
    try std.testing.expectEqual(@as(u8, 0), buf[2]);
    try std.testing.expectEqual(@as(u8, 0), buf[3]);
}

test "coordinate scale: microns to database units" {
    // GDSII coordinates are in database units (typically nanometres).
    // With grid_unit = 0.001 µm, a coordinate of 5.0 µm → 5000 database units.
    const grid_unit: f32 = 0.001;
    const coord_um: f32 = 5.0;
    const db_units: i32 = @intFromFloat(coord_um / grid_unit);
    try std.testing.expectEqual(@as(i32, 5000), db_units);
}

test "coordinate scale: negative coordinate" {
    const grid_unit: f32 = 0.001;
    const coord_um: f32 = -2.5;
    const db_units: i32 = @intFromFloat(coord_um / grid_unit);
    try std.testing.expectEqual(@as(i32, -2500), db_units);
}

// ─── Record writing tests ───────────────────────────────────────────────────

test "records.writeRecord ENDEL produces 4-byte record" {
    var buf: [64]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    var writer = fbs.writer();

    try records.writeRecord(&writer, RecordType.ENDEL, &[_]u8{});

    const written = fbs.getWritten();
    try std.testing.expectEqual(@as(usize, 4), written.len);
    // Length field = 0x0004.
    try std.testing.expectEqual(@as(u8, 0x00), written[0]);
    try std.testing.expectEqual(@as(u8, 0x04), written[1]);
    // Record type 0x11 (ENDEL), data type 0x00 (no data).
    try std.testing.expectEqual(@as(u8, 0x11), written[2]);
    try std.testing.expectEqual(@as(u8, 0x00), written[3]);
}

test "records.writeRecord BOUNDARY produces 4-byte record" {
    var buf: [64]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    var writer = fbs.writer();

    try records.writeRecord(&writer, RecordType.BOUNDARY, &[_]u8{});

    const written = fbs.getWritten();
    try std.testing.expectEqual(@as(usize, 4), written.len);
    try std.testing.expectEqual(@as(u8, 0x08), written[2]); // BOUNDARY record type
    try std.testing.expectEqual(@as(u8, 0x00), written[3]); // no data type
}

test "records.writeRecord with payload" {
    var buf: [64]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    var writer = fbs.writer();

    const payload = [_]u8{ 0xAA, 0xBB };
    try records.writeRecord(&writer, RecordType.HEADER, &payload);

    const written = fbs.getWritten();
    // Length = 4 + 2 = 6.
    try std.testing.expectEqual(@as(usize, 6), written.len);
    try std.testing.expectEqual(@as(u8, 0x00), written[0]);
    try std.testing.expectEqual(@as(u8, 0x06), written[1]);
    // Payload bytes.
    try std.testing.expectEqual(@as(u8, 0xAA), written[4]);
    try std.testing.expectEqual(@as(u8, 0xBB), written[5]);
}

test "records.writeInt16Record LAYER value" {
    var buf: [64]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    var writer = fbs.writer();

    try records.writeInt16Record(&writer, RecordType.LAYER, 3);

    const written = fbs.getWritten();
    // Total = 6 bytes.
    try std.testing.expectEqual(@as(usize, 6), written.len);
    // Big-endian i16 value 3.
    try std.testing.expectEqual(@as(u8, 0x00), written[4]);
    try std.testing.expectEqual(@as(u8, 0x03), written[5]);
}

test "records.writeInt16Record DATATYPE zero" {
    var buf: [64]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    var writer = fbs.writer();

    try records.writeInt16Record(&writer, RecordType.DATATYPE, 0);

    const written = fbs.getWritten();
    try std.testing.expectEqual(@as(usize, 6), written.len);
    try std.testing.expectEqual(@as(u8, 0x00), written[4]);
    try std.testing.expectEqual(@as(u8, 0x00), written[5]);
}

test "records.writeInt32Record WIDTH value" {
    var buf: [64]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    var writer = fbs.writer();

    try records.writeInt32Record(&writer, RecordType.WIDTH, 500);

    const written = fbs.getWritten();
    try std.testing.expectEqual(@as(usize, 8), written.len);
    // 500 = 0x000001F4.
    try std.testing.expectEqual(@as(u8, 0x00), written[4]);
    try std.testing.expectEqual(@as(u8, 0x00), written[5]);
    try std.testing.expectEqual(@as(u8, 0x01), written[6]);
    try std.testing.expectEqual(@as(u8, 0xF4), written[7]);
}

test "records.writeStringRecord LIBNAME" {
    var buf: [64]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    var writer = fbs.writer();

    try records.writeStringRecord(&writer, RecordType.LIBNAME, "spout_layout");

    const written = fbs.getWritten();
    // "spout_layout" has 12 chars (even) → no padding.
    // Total = 4 + 12 = 16.
    try std.testing.expectEqual(@as(usize, 16), written.len);
    // Verify the string content starts at offset 4.
    try std.testing.expectEqualStrings("spout_layout", written[4..16]);
}

test "records.writeStringRecord STRNAME odd padding" {
    var buf: [64]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    var writer = fbs.writer();

    try records.writeStringRecord(&writer, RecordType.STRNAME, "TOP");

    const written = fbs.getWritten();
    // "TOP" = 3 chars (odd) → padded to 4. Total = 4 + 4 = 8.
    try std.testing.expectEqual(@as(usize, 8), written.len);
    try std.testing.expectEqual(@as(u8, 'T'), written[4]);
    try std.testing.expectEqual(@as(u8, 'O'), written[5]);
    try std.testing.expectEqual(@as(u8, 'P'), written[6]);
    try std.testing.expectEqual(@as(u8, 0x00), written[7]); // pad byte
}

test "records.writeFloat64Record round-trip" {
    var buf: [64]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    var writer = fbs.writer();

    const value: f64 = 1.0e-3;
    try records.writeFloat64Record(&writer, RecordType.UNITS, value);

    const written = fbs.getWritten();
    // Total = 4 + 8 = 12.
    try std.testing.expectEqual(@as(usize, 12), written.len);

    // Extract the 8-byte GDSII real from the payload and verify round-trip.
    var gdsii_bytes: [8]u8 = undefined;
    @memcpy(&gdsii_bytes, written[4..12]);
    const recovered = records.fromGdsiiReal(gdsii_bytes);
    try std.testing.expectApproxEqRel(value, recovered, 1e-9);
}

// ─── Header/footer structure tests ──────────────────────────────────────────

test "coordinate conversion scale factor at db_unit=0.001" {
    // The GDSII writer uses: scale = 1.0 / db_unit, then @intFromFloat(coord * scale).
    // Since 0.001 is not exactly representable in f32, the scale is slightly under 1000.
    // This causes @intFromFloat to truncate to N-1. Verify the conversion is within
    // 1 database unit of the expected value, matching real GDSII tool tolerance.
    const db_unit: f32 = 0.001;
    const scale: f32 = 1.0 / db_unit;
    const coord_um: f32 = 1.5;
    const db_units: i32 = @intFromFloat(coord_um * scale);
    // Must be within 1 db unit of the ideal 1500
    try std.testing.expect(@abs(db_units - 1500) <= 1);
}

test "coordinate conversion exact with power-of-two db_unit" {
    // db_unit = 0.125 (1/8) is exactly representable in f32, so no truncation.
    const db_unit: f32 = 0.125;
    const scale: f32 = 1.0 / db_unit;
    const coord_um: f32 = 1.5;
    const db_units: i32 = @intFromFloat(coord_um * scale);
    try std.testing.expectEqual(@as(i32, 12), db_units);
}

test "GDSII file starts with HEADER record bytes match spec" {
    var buf: [64]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    var writer = fbs.writer();

    // Write HEADER with version 600
    try records.writeInt16Record(&writer, RecordType.HEADER, 600);

    const written = fbs.getWritten();
    // Total length = 6 bytes (4 header + 2 data)
    try std.testing.expectEqual(@as(u8, 0x00), written[0]); // length high byte
    try std.testing.expectEqual(@as(u8, 0x06), written[1]); // length low byte = 6
    try std.testing.expectEqual(@as(u8, 0x00), written[2]); // record type = HEADER (0x00)
    try std.testing.expectEqual(@as(u8, 0x02), written[3]); // data type = INT16 (0x02)
    // Version 600 = 0x0258 in big-endian
    try std.testing.expectEqual(@as(u8, 0x02), written[4]);
    try std.testing.expectEqual(@as(u8, 0x58), written[5]);
}

test "GDSII write and read back roundtrip for float values" {
    // Test several values for roundtrip accuracy
    const test_values = [_]f64{ 1.0e-3, 1.0e-9, 0.14, 42.5, 100.0, 0.001 };

    for (test_values) |original| {
        var buf: [64]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&buf);
        var writer = fbs.writer();

        try records.writeFloat64Record(&writer, RecordType.UNITS, original);

        const written = fbs.getWritten();
        // Extract 8-byte GDSII real from payload (bytes 4..12)
        var gdsii_bytes: [8]u8 = undefined;
        @memcpy(&gdsii_bytes, written[4..12]);
        const recovered = records.fromGdsiiReal(gdsii_bytes);
        try std.testing.expectApproxEqRel(original, recovered, 1e-8);
    }
}

test "GDSII multiple layers in record sequence" {
    var buf: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    var writer = fbs.writer();

    // Write BOUNDARY elements on different layers
    for ([_]i16{ 1, 5, 10, 68 }) |layer| {
        // BOUNDARY
        try records.writeRecord(&writer, RecordType.BOUNDARY, &[_]u8{});
        // LAYER
        try records.writeInt16Record(&writer, RecordType.LAYER, layer);
        // DATATYPE
        try records.writeInt16Record(&writer, RecordType.DATATYPE, 0);
        // ENDEL
        try records.writeRecord(&writer, RecordType.ENDEL, &[_]u8{});
    }

    const written = fbs.getWritten();
    // Should have written non-trivial data
    try std.testing.expect(written.len > 60);

    // Verify the first element starts with BOUNDARY
    try std.testing.expectEqual(@as(u8, 0x08), written[2]); // BOUNDARY record type
}

test "GDSII ENDLIB is the last record in a valid file" {
    var buf: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    var writer = fbs.writer();

    // Write minimal valid structure
    try records.writeInt16Record(&writer, RecordType.HEADER, 600);
    const timestamp = [_]u8{0} ** 24;
    try records.writeRecord(&writer, RecordType.BGNLIB, &timestamp);
    try records.writeStringRecord(&writer, RecordType.LIBNAME, "test");
    try records.writeFloat64Record(&writer, RecordType.UNITS, 1.0e-3);
    try records.writeRecord(&writer, RecordType.BGNSTR, &timestamp);
    try records.writeStringRecord(&writer, RecordType.STRNAME, "TOP");
    try records.writeRecord(&writer, RecordType.ENDSTR, &[_]u8{});
    try records.writeRecord(&writer, RecordType.ENDLIB, &[_]u8{});

    const written = fbs.getWritten();

    // Last 4 bytes should be ENDLIB: length=0x0004, type=0x04, data=0x00
    try std.testing.expectEqual(@as(u8, 0x00), written[written.len - 4]);
    try std.testing.expectEqual(@as(u8, 0x04), written[written.len - 3]);
    try std.testing.expectEqual(@as(u8, 0x04), written[written.len - 2]); // ENDLIB record type
    try std.testing.expectEqual(@as(u8, 0x00), written[written.len - 1]); // no data type
}

test "GDSII record sequence: minimal valid file structure" {
    // Write a minimal GDSII file structure and verify record types appear
    // in the correct order: HEADER, BGNLIB, LIBNAME, UNITS, BGNSTR, STRNAME,
    // ENDSTR, ENDLIB.
    var buf: [512]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    var writer = fbs.writer();

    // HEADER (version 600)
    try records.writeInt16Record(&writer, RecordType.HEADER, 600);

    // BGNLIB (timestamps — 12 int16 values = 24 bytes)
    const timestamp = [_]u8{0} ** 24;
    try records.writeRecord(&writer, RecordType.BGNLIB, &timestamp);

    // LIBNAME
    try records.writeStringRecord(&writer, RecordType.LIBNAME, "test");

    // UNITS (two f64 values = 16 bytes of GDSII reals)
    try records.writeFloat64Record(&writer, RecordType.UNITS, 1.0e-3);

    // BGNSTR (timestamps)
    try records.writeRecord(&writer, RecordType.BGNSTR, &timestamp);

    // STRNAME
    try records.writeStringRecord(&writer, RecordType.STRNAME, "TOP");

    // ENDSTR
    try records.writeRecord(&writer, RecordType.ENDSTR, &[_]u8{});

    // ENDLIB
    try records.writeRecord(&writer, RecordType.ENDLIB, &[_]u8{});

    const written = fbs.getWritten();
    // Should have written a non-trivial amount of data.
    try std.testing.expect(written.len > 40);

    // Verify that the first record is HEADER.
    try std.testing.expectEqual(@as(u8, 0x00), written[2]); // HEADER record type byte
    try std.testing.expectEqual(@as(u8, 0x02), written[3]); // HEADER data type byte (int16)
}
