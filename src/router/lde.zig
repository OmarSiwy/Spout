// LDE Router — Layout Dependent Effects routing for analog circuits.
//
// LDE effects cause MOSFET characteristics to vary based on proximity to other
// devices or wells.  The LDE router provides a constraint database (SA/SB spacing)
// and a cost function for A* expansion that penalizes SA/SB asymmetry between
// matched devices.

const std = @import("std");
const core_types = @import("../core/types.zig");

const DeviceIdx = core_types.DeviceIdx;
const DeviceType = core_types.DeviceType;

// ─── Geometry ───────────────────────────────────────────────────────────────

pub const Rect = struct {
    x1: f32,
    y1: f32,
    x2: f32,
    y2: f32,

    pub fn width(self: Rect) f32 { return self.x2 - self.x1; }
    pub fn height(self: Rect) f32 { return self.y2 - self.y1; }
    pub fn centerX(self: Rect) f32 { return (self.x1 + self.x2) * 0.5; }
    pub fn centerY(self: Rect) f32 { return (self.y1 + self.y2) * 0.5; }

    pub fn overlaps(self: Rect, other: Rect) bool {
        return self.x1 < other.x2 and self.x2 > other.x1 and
               self.y1 < other.y2 and self.y2 > other.y1;
    }

    pub fn expand(self: Rect, amount: f32) Rect {
        return .{
            .x1 = self.x1 - amount,
            .y1 = self.y1 - amount,
            .x2 = self.x2 + amount,
            .y2 = self.y2 + amount,
        };
    }

    /// Returns a new rect expanded on specific sides only.
    pub fn expandAsymmetric(self: Rect, left: f32, right: f32, bottom: f32, top: f32) Rect {
        return .{
            .x1 = self.x1 - left,
            .y1 = self.y1 - bottom,
            .x2 = self.x2 + right,
            .y2 = self.y2 + top,
        };
    }
};

// ─── LDE Constraint ─────────────────────────────────────────────────────────

pub const LDEConstraint = struct {
    device: DeviceIdx,
    min_sa: f32,
    max_sa: f32,
    min_sb: f32,
    max_sb: f32,
    sc_target: f32,
};

// ─── LDEConstraintDB ─────────────────────────────────────────────────────────

/// Structure-of-Arrays database for LDE constraints.
pub const LDEConstraintDB = struct {
    allocator: std.mem.Allocator,
    device: std.ArrayListUnmanaged(DeviceIdx),
    min_sa: std.ArrayListUnmanaged(f32),
    max_sa: std.ArrayListUnmanaged(f32),
    min_sb: std.ArrayListUnmanaged(f32),
    max_sb: std.ArrayListUnmanaged(f32),
    sc_target: std.ArrayListUnmanaged(f32),

    pub fn init(allocator: std.mem.Allocator, capacity: u32) !LDEConstraintDB {
        var device = try std.ArrayListUnmanaged(DeviceIdx).initCapacity(allocator, capacity);
        errdefer device.deinit(allocator);
        var min_sa = try std.ArrayListUnmanaged(f32).initCapacity(allocator, capacity);
        errdefer min_sa.deinit(allocator);
        var max_sa = try std.ArrayListUnmanaged(f32).initCapacity(allocator, capacity);
        errdefer max_sa.deinit(allocator);
        var min_sb = try std.ArrayListUnmanaged(f32).initCapacity(allocator, capacity);
        errdefer min_sb.deinit(allocator);
        var max_sb = try std.ArrayListUnmanaged(f32).initCapacity(allocator, capacity);
        errdefer max_sb.deinit(allocator);
        var sc_target = try std.ArrayListUnmanaged(f32).initCapacity(allocator, capacity);
        errdefer sc_target.deinit(allocator);

        return .{
            .allocator = allocator,
            .device = device,
            .min_sa = min_sa,
            .max_sa = max_sa,
            .min_sb = min_sb,
            .max_sb = max_sb,
            .sc_target = sc_target,
        };
    }

    pub fn deinit(self: *LDEConstraintDB) void {
        self.device.deinit(self.allocator);
        self.min_sa.deinit(self.allocator);
        self.max_sa.deinit(self.allocator);
        self.min_sb.deinit(self.allocator);
        self.max_sb.deinit(self.allocator);
        self.sc_target.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn addConstraint(self: *LDEConstraintDB, constraint: LDEConstraint) !void {
        try self.device.append(self.allocator, constraint.device);
        try self.min_sa.append(self.allocator, constraint.min_sa);
        try self.max_sa.append(self.allocator, constraint.max_sa);
        try self.min_sb.append(self.allocator, constraint.min_sb);
        try self.max_sb.append(self.allocator, constraint.max_sb);
        try self.sc_target.append(self.allocator, constraint.sc_target);
    }

    pub fn len(self: *const LDEConstraintDB) u32 {
        return @as(u32, @intCast(self.device.items.len));
    }

    pub fn getConstraint(self: *const LDEConstraintDB, idx: u32) ?LDEConstraint {
        if (idx >= self.len()) return null;
        return .{
            .device = self.device.items[idx],
            .min_sa = self.min_sa.items[idx],
            .max_sa = self.max_sa.items[idx],
            .min_sb = self.min_sb.items[idx],
            .max_sb = self.max_sb.items[idx],
            .sc_target = self.sc_target.items[idx],
        };
    }

    /// Find the constraint index for a given device, or null if not found.
    pub fn findByDevice(self: *const LDEConstraintDB, device: DeviceIdx) ?u32 {
        for (0..self.device.items.len) |i| {
            if (self.device.items[i].toInt() == device.toInt()) {
                return @as(u32, @intCast(i));
            }
        }
        return null;
    }

    /// Generate keepout rectangles for all devices with LDE constraints.
    /// Each keepout is the device bbox expanded by min_sa (source side) and
    /// min_sb (body side) based on device orientation.
    ///
    /// device_bboxes must be indexed by DeviceIdx.toInt().
    pub fn generateKeepouts(
        self: *const LDEConstraintDB,
        device_bboxes: []const Rect,
        device_types: []const DeviceType,
        allocator: std.mem.Allocator,
    ) ![]Rect {
        var rects = std.ArrayListUnmanaged(Rect){};
        errdefer rects.deinit(allocator);

        for (0..self.device.items.len) |i| {
            const dev = self.device.items[i];
            const dev_int = dev.toInt();
            if (dev_int >= device_bboxes.len or dev_int >= device_types.len) continue;

            const bbox = device_bboxes[dev_int];
            const dev_type = device_types[dev_int];

            const sa = self.min_sa.items[i];
            const sb = self.min_sb.items[i];

            // SA = Source to Active edge spacing
            // SB = Body to Active edge spacing
            // For NMOS: left = source, right = body
            // For PMOS: right = source, left = body
            const keepout = switch (dev_type) {
                .nmos, .res_diff_n => bbox.expandAsymmetric(sa, sb, 0, 0),
                .pmos, .res_diff_p => bbox.expandAsymmetric(sb, sa, 0, 0),
                else => bbox.expand(@max(sa, sb)), // conservative: symmetric expansion
            };

            try rects.append(allocator, keepout);
        }

        return try rects.toOwnedSlice(allocator);
    }

    /// Generate WPE exclusion zones based on sc_target.
    /// SCA = Active to Well edge distance.
    /// Keepout ensures routing does not alter SCA from target.
    pub fn generateWPEKeepouts(
        self: *const LDEConstraintDB,
        device_bboxes: []const Rect,
        device_types: []const DeviceType,
        allocator: std.mem.Allocator,
    ) ![]Rect {
        var rects = std.ArrayListUnmanaged(Rect){};
        errdefer rects.deinit(allocator);

        for (0..self.device.items.len) |i| {
            const sc = self.sc_target.items[i];
            if (sc <= 0) continue; // No WPE constraint

            const dev = self.device.items[i];
            const dev_int = dev.toInt();
            if (dev_int >= device_bboxes.len or dev_int >= device_types.len) continue;

            const bbox = device_bboxes[dev_int];
            const dev_type = device_types[dev_int];

            // WPE exclusion zone: expand well-facing side by sc_target
            const wpe_zone = switch (dev_type) {
                .nmos, .res_diff_n => bbox.expandAsymmetric(0, 0, 0, sc), // top = well side
                .pmos, .res_diff_p => bbox.expandAsymmetric(0, 0, sc, 0), // bottom = well side
                else => continue,
            };

            try rects.append(allocator, wpe_zone);
        }

        return try rects.toOwnedSlice(allocator);
    }
};

// ─── LDE Cost for A* ────────────────────────────────────────────────────────

/// Compute LDE cost penalizing SA/SB asymmetry between two devices.
/// Returns |SA_a - SA_b| + |SB_a - SB_b|.
pub fn computeLDECost(sa_a: f32, sb_a: f32, sa_b: f32, sb_b: f32) f32 {
    const sa_diff = @abs(sa_a - sa_b);
    const sb_diff = @abs(sb_a - sb_b);
    return sa_diff + sb_diff;
}

/// Compute LDE cost with tolerance threshold.
/// Only penalizes differences exceeding the tolerance.
pub fn computeLDECostScaled(
    sa_a: f32, sb_a: f32,
    sa_b: f32, sb_b: f32,
    tolerance: f32,
) f32 {
    const sa_diff = @abs(sa_a - sa_b);
    const sb_diff = @abs(sb_a - sb_b);
    const sa_score = if (sa_diff > tolerance) sa_diff - tolerance else 0;
    const sb_score = if (sb_diff > tolerance) sb_diff - tolerance else 0;
    return sa_score + sb_score;
}

// ─── Tests ───────────────────────────────────────────────────────────────────

test "LDEConstraintDB init and addConstraint" {
    const alloc = std.testing.allocator;

    var db = try LDEConstraintDB.init(alloc, 8);
    defer db.deinit();

    try db.addConstraint(.{
        .device = DeviceIdx.fromInt(0),
        .min_sa = 1.0,
        .max_sa = 5.0,
        .min_sb = 1.0,
        .max_sb = 5.0,
        .sc_target = 2.0,
    });

    try std.testing.expectEqual(@as(u32, 1), db.len());

    const c = db.getConstraint(0);
    try std.testing.expect(c != null);
    try std.testing.expectEqual(@as(f32, 1.0), c.?.min_sa);
    try std.testing.expectEqual(@as(f32, 2.0), c.?.sc_target);
}

test "LDEConstraintDB add multiple constraints" {
    const alloc = std.testing.allocator;

    var db = try LDEConstraintDB.init(alloc, 4);
    defer db.deinit();

    try db.addConstraint(.{
        .device = DeviceIdx.fromInt(0),
        .min_sa = 1.0, .max_sa = 5.0,
        .min_sb = 1.0, .max_sb = 5.0,
        .sc_target = 2.0,
    });
    try db.addConstraint(.{
        .device = DeviceIdx.fromInt(1),
        .min_sa = 1.5, .max_sa = 6.0,
        .min_sb = 1.2, .max_sb = 6.0,
        .sc_target = 2.5,
    });

    try std.testing.expectEqual(@as(u32, 2), db.len());

    const c0 = db.getConstraint(0);
    const c1 = db.getConstraint(1);
    try std.testing.expectEqual(DeviceIdx.fromInt(0), c0.?.device);
    try std.testing.expectEqual(DeviceIdx.fromInt(1), c1.?.device);
}

test "LDEConstraintDB findByDevice" {
    const alloc = std.testing.allocator;

    var db = try LDEConstraintDB.init(alloc, 4);
    defer db.deinit();

    try db.addConstraint(.{
        .device = DeviceIdx.fromInt(42),
        .min_sa = 1.0, .max_sa = 5.0,
        .min_sb = 1.0, .max_sb = 5.0,
        .sc_target = 2.0,
    });

    const idx = db.findByDevice(DeviceIdx.fromInt(42));
    try std.testing.expect(idx != null);
    try std.testing.expectEqual(@as(u32, 0), idx.?);

    const missing = db.findByDevice(DeviceIdx.fromInt(99));
    try std.testing.expect(missing == null);
}

test "generateKeepouts for NMOS" {
    const alloc = std.testing.allocator;

    var db = try LDEConstraintDB.init(alloc, 4);
    defer db.deinit();

    try db.addConstraint(.{
        .device = DeviceIdx.fromInt(0),
        .min_sa = 1.0,
        .max_sa = 5.0,
        .min_sb = 2.0,
        .max_sb = 6.0,
        .sc_target = 0.0,
    });

    const bboxes = &[_]Rect{
        Rect{ .x1 = 10.0, .y1 = 20.0, .x2 = 30.0, .y2 = 40.0 }, // device 0
    };
    const types = &[_]DeviceType{
        .nmos, // device 0
    };

    const keepouts = try db.generateKeepouts(bboxes, types, alloc);
    defer alloc.free(keepouts);

    try std.testing.expectEqual(@as(usize, 1), keepouts.len);

    // NMOS: left = source (SA), right = body (SB)
    // keepout expanded by SA on left, SB on right
    try std.testing.expect(keepouts[0].x1 < 10.0); // expanded left by SA
    try std.testing.expect(keepouts[0].x2 > 30.0); // expanded right by SB
    try std.testing.expectEqual(@as(f32, 20.0), keepouts[0].y1); // no vertical change
    try std.testing.expectEqual(@as(f32, 40.0), keepouts[0].y2);
}

test "generateKeepouts for PMOS" {
    const alloc = std.testing.allocator;

    var db = try LDEConstraintDB.init(alloc, 4);
    defer db.deinit();

    try db.addConstraint(.{
        .device = DeviceIdx.fromInt(0),
        .min_sa = 1.0,
        .max_sa = 5.0,
        .min_sb = 2.0,
        .max_sb = 6.0,
        .sc_target = 0.0,
    });

    const bboxes = &[_]Rect{
        Rect{ .x1 = 10.0, .y1 = 20.0, .x2 = 30.0, .y2 = 40.0 },
    };
    const types = &[_]DeviceType{
        .pmos, // device 0
    };

    const keepouts = try db.generateKeepouts(bboxes, types, alloc);
    defer alloc.free(keepouts);

    try std.testing.expectEqual(@as(usize, 1), keepouts.len);

    // PMOS: right = source (SA), left = body (SB)
    // keepout expanded by SB on left, SA on right
    try std.testing.expect(keepouts[0].x1 < 10.0); // expanded left by SB
    try std.testing.expect(keepouts[0].x2 > 30.0); // expanded right by SA
}

test "generateKeepouts for device with no constraint" {
    const alloc = std.testing.allocator;

    var db = try LDEConstraintDB.init(alloc, 4);
    defer db.deinit();

    // No constraints added

    const bboxes = &[_]Rect{
        Rect{ .x1 = 10.0, .y1 = 20.0, .x2 = 30.0, .y2 = 40.0 },
    };
    const types = &[_]DeviceType{
        .nmos,
    };

    const keepouts = try db.generateKeepouts(bboxes, types, alloc);
    defer alloc.free(keepouts);

    // No constraints = no keepouts
    try std.testing.expectEqual(@as(usize, 0), keepouts.len);
}

test "computeLDECost returns zero for symmetric SA/SB" {
    const cost = computeLDECost(1.0, 1.0, 1.0, 1.0);
    try std.testing.expectEqual(@as(f32, 0.0), cost);
}

test "computeLDECost penalizes asymmetry" {
    const cost_sym = computeLDECost(1.0, 1.0, 1.0, 1.0);
    const cost_asym = computeLDECost(1.0, 1.0, 0.5, 0.5);

    try std.testing.expect(cost_asym > cost_sym);
    try std.testing.expect(cost_asym > 0.0);
}

test "computeLDECostScaled respects tolerance" {
    const cost_within_tol = computeLDECostScaled(1.0, 1.0, 1.0, 1.0, 0.1);
    try std.testing.expectEqual(@as(f32, 0.0), cost_within_tol);

    const cost_outside_tol = computeLDECostScaled(1.0, 1.0, 0.5, 0.5, 0.1);
    try std.testing.expect(cost_outside_tol > 0.0);

    // The penalty should be (diff - tolerance)
    // SA diff = 0.5, tolerance = 0.1, so penalty = 0.4
    // SB diff = 0.5, tolerance = 0.1, so penalty = 0.4
    // Total = 0.8
    try std.testing.expectApproxEqAbs(@as(f32, 0.8), cost_outside_tol, 0.001);
}

test "generateWPEKeepouts" {
    const alloc = std.testing.allocator;

    var db = try LDEConstraintDB.init(alloc, 4);
    defer db.deinit();

    try db.addConstraint(.{
        .device = DeviceIdx.fromInt(0),
        .min_sa = 1.0, .max_sa = 5.0,
        .min_sb = 1.0, .max_sb = 5.0,
        .sc_target = 3.0, // WPE constraint
    });

    const bboxes = &[_]Rect{
        Rect{ .x1 = 10.0, .y1 = 20.0, .x2 = 30.0, .y2 = 40.0 },
    };
    const types = &[_]DeviceType{
        .nmos,
    };

    const wpe_rects = try db.generateWPEKeepouts(bboxes, types, alloc);
    defer alloc.free(wpe_rects);

    try std.testing.expectEqual(@as(usize, 1), wpe_rects.len);

    // NMOS: top = well side, so y2 expanded by sc_target
    try std.testing.expectEqual(@as(f32, 10.0), wpe_rects[0].x1); // no horizontal change
    try std.testing.expectEqual(@as(f32, 20.0), wpe_rects[0].y1); // no change at bottom
    try std.testing.expectEqual(@as(f32, 30.0), wpe_rects[0].x2); // no change at right
    try std.testing.expect(wpe_rects[0].y2 > 40.0); // expanded top
}

test "generateWPEKeepouts skips zero sc_target" {
    const alloc = std.testing.allocator;

    var db = try LDEConstraintDB.init(alloc, 4);
    defer db.deinit();

    try db.addConstraint(.{
        .device = DeviceIdx.fromInt(0),
        .min_sa = 1.0, .max_sa = 5.0,
        .min_sb = 1.0, .max_sb = 5.0,
        .sc_target = 0.0, // No WPE constraint
    });

    const bboxes = &[_]Rect{
        Rect{ .x1 = 10.0, .y1 = 20.0, .x2 = 30.0, .y2 = 40.0 },
    };
    const types = &[_]DeviceType{
        .nmos,
    };

    const wpe_rects = try db.generateWPEKeepouts(bboxes, types, alloc);
    defer alloc.free(wpe_rects);

    try std.testing.expectEqual(@as(usize, 0), wpe_rects.len);
}

test "Rect expandAsymmetric" {
    const r = Rect{ .x1 = 10.0, .y1 = 20.0, .x2 = 30.0, .y2 = 40.0 };
    const expanded = r.expandAsymmetric(5.0, 10.0, 3.0, 7.0);

    try std.testing.expectEqual(@as(f32, 5.0), expanded.x1);  // 10 - 5
    try std.testing.expectEqual(@as(f32, 17.0), expanded.y1); // 20 - 3
    try std.testing.expectEqual(@as(f32, 40.0), expanded.x2); // 30 + 10
    try std.testing.expectEqual(@as(f32, 47.0), expanded.y2); // 40 + 7
}

test "Rect expand is symmetric" {
    const r = Rect{ .x1 = 10.0, .y1 = 20.0, .x2 = 30.0, .y2 = 40.0 };
    const expanded = r.expand(5.0);

    const asym = r.expandAsymmetric(5.0, 5.0, 5.0, 5.0);
    try std.testing.expectEqual(expanded.x1, asym.x1);
    try std.testing.expectEqual(expanded.y1, asym.y1);
    try std.testing.expectEqual(expanded.x2, asym.x2);
    try std.testing.expectEqual(expanded.y2, asym.y2);
}
