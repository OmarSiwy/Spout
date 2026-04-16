//! Analog router type definitions.
//! Defines enums, geometry structs, and compile-time layout assertions.

const std = @import("std");
const core_types = @import("../core/types.zig");

// Re-export core IDs so router modules can import from one place.
pub const NetIdx = core_types.NetIdx;
pub const DeviceIdx = core_types.DeviceIdx;
pub const LayerIdx = core_types.LayerIdx;

// ── Analog-specific ID types (not in core/types.zig) ────────────────────────

pub const AnalogGroupIdx = enum(u32) {
    _,
    pub inline fn toInt(self: @This()) u32 { return @intFromEnum(self); }
    pub inline fn fromInt(v: u32) @This() { return @enumFromInt(v); }
};

pub const SegmentIdx = enum(u32) {
    _,
    pub inline fn toInt(self: @This()) u32 { return @intFromEnum(self); }
    pub inline fn fromInt(v: u32) @This() { return @enumFromInt(v); }
};

pub const ShieldIdx = enum(u32) {
    _,
    pub inline fn toInt(self: @This()) u32 { return @intFromEnum(self); }
    pub inline fn fromInt(v: u32) @This() { return @enumFromInt(v); }
};

pub const GuardRingIdx = enum(u16) {
    _,
    pub inline fn toInt(self: @This()) u16 { return @intFromEnum(self); }
    pub inline fn fromInt(v: u16) @This() { return @enumFromInt(v); }
};

pub const ThermalCellIdx = enum(u32) {
    _,
    pub inline fn toInt(self: @This()) u32 { return @intFromEnum(self); }
    pub inline fn fromInt(v: u32) @This() { return @enumFromInt(v); }
};

pub const CentroidPatternIdx = enum(u32) {
    _,
    pub inline fn toInt(self: @This()) u32 { return @intFromEnum(self); }
    pub inline fn fromInt(v: u32) @This() { return @enumFromInt(v); }
};

// ── Enums ────────────────────────────────────────────────────────────────────

pub const AnalogGroupType = enum(u8) {
    differential,      // 2 nets, mirrored routing
    matched,           // N nets, same R/C/length/vias
    shielded,          // 1 signal net + shield net
    kelvin,            // force + sense nets (4-wire)
    resistor_matched,  // resistor segments in common centroid
    capacitor_array,  // unit cap array routing
};

pub const GuardRingType = enum(u8) {
    p_plus,
    n_plus,
    deep_nwell,
    substrate,
};

pub const GroupStatus = enum(u8) {
    pending,
    routing,
    routed,
    failed,
};

pub const RepairAction = enum(u8) {
    none,
    adjust_width,     // R mismatch -> widen/narrow
    adjust_layer,     // C mismatch -> move to different layer
    add_jog,          // length mismatch -> serpentine
    add_dummy_via,    // via count mismatch -> insert dummy
    rebalance_layer,  // coupling mismatch -> reassign layers
};

pub const RoutingResult = enum(u8) {
    success,
    mismatch_exceeded, // converged but above tolerance
    no_path,           // A* found no route
    max_iterations,    // PEX loop exhausted
};

pub const SymmetryAxis = enum(u8) {
    x, // horizontal axis (mirror across y)
    y, // vertical axis (mirror across x)
};

// ── Geometry Structs ─────────────────────────────────────────────────────────

pub const Rect = struct {
    x1: f32,
    y1: f32,
    x2: f32,
    y2: f32,

    pub fn width(self: Rect) f32 {
        return self.x2 - self.x1;
    }

    pub fn height(self: Rect) f32 {
        return self.y2 - self.y1;
    }

    pub fn area(self: Rect) f32 {
        return self.width() * self.height();
    }

    pub fn centerX(self: Rect) f32 {
        return (self.x1 + self.x2) * 0.5;
    }

    pub fn centerY(self: Rect) f32 {
        return (self.y1 + self.y2) * 0.5;
    }

    pub fn overlaps(self: Rect, other: Rect) bool {
        return self.x1 < other.x2 and self.x2 > other.x1 and
            self.y1 < other.y2 and self.y2 > other.y1;
    }

    pub fn overlapsWithMargin(self: Rect, other: Rect, margin: f32) bool {
        return (self.x1 - margin) < other.x2 and (self.x2 + margin) > other.x1 and
            (self.y1 - margin) < other.y2 and (self.y2 + margin) > other.y1;
    }

    pub fn expand(self: Rect, amount: f32) Rect {
        return .{
            .x1 = self.x1 - amount,
            .y1 = self.y1 - amount,
            .x2 = self.x2 + amount,
            .y2 = self.y2 + amount,
        };
    }

    pub fn union_(self: Rect, other: Rect) Rect {
        return .{
            .x1 = @min(self.x1, other.x1),
            .y1 = @min(self.y1, other.y1),
            .x2 = @max(self.x2, other.x2),
            .y2 = @max(self.y2, other.y2),
        };
    }

    pub fn containsPoint(self: Rect, x: f32, y: f32) bool {
        return x >= self.x1 and x < self.x2 and y >= self.y1 and y < self.y2;
    }
};

/// Pin is a named point on a net, used for analog routing targets.
pub const Pin = struct {
    x: f32,
    y: f32,
    net: NetIdx,
    name: []const u8,
};

// ── Compile-time layout assertions ──────────────────────────────────────────

comptime {
    std.debug.assert(@sizeOf(AnalogGroupIdx) == 4);
    std.debug.assert(@sizeOf(SegmentIdx) == 4);
    std.debug.assert(@sizeOf(ShieldIdx) == 4);
    std.debug.assert(@sizeOf(GuardRingIdx) == 2);
    std.debug.assert(@sizeOf(ThermalCellIdx) == 4);
    std.debug.assert(@sizeOf(AnalogGroupType) == 1);
    std.debug.assert(@sizeOf(GuardRingType) == 1);
    std.debug.assert(@sizeOf(GroupStatus) == 1);
    std.debug.assert(@sizeOf(RepairAction) == 1);
    std.debug.assert(@sizeOf(RoutingResult) == 1);
    std.debug.assert(@sizeOf(SymmetryAxis) == 1);
}

// ── Tests ────────────────────────────────────────────────────────────────────

test "Rect width/height/area" {
    const r = Rect{ .x1 = 10.0, .y1 = 5.0, .x2 = 30.0, .y2 = 15.0 };
    try std.testing.expectEqual(@as(f32, 20.0), r.width());
    try std.testing.expectEqual(@as(f32, 10.0), r.height());
    try std.testing.expectEqual(@as(f32, 200.0), r.area());
}

test "Rect overlaps" {
    const r1 = Rect{ .x1 = 0.0, .y1 = 0.0, .x2 = 10.0, .y2 = 10.0 };
    const r2 = Rect{ .x1 = 5.0, .y1 = 5.0, .x2 = 15.0, .y2 = 15.0 };
    try std.testing.expect(r1.overlaps(r2));
}

test "Rect non-overlapping" {
    const r1 = Rect{ .x1 = 0.0, .y1 = 0.0, .x2 = 10.0, .y2 = 10.0 };
    const r2 = Rect{ .x1 = 20.0, .y1 = 20.0, .x2 = 30.0, .y2 = 30.0 };
    try std.testing.expect(!r1.overlaps(r2));
}

test "Rect overlapsWithMargin" {
    const r1 = Rect{ .x1 = 0.0, .y1 = 0.0, .x2 = 10.0, .y2 = 10.0 };
    const r2 = Rect{ .x1 = 12.0, .y1 = 12.0, .x2 = 20.0, .y2 = 20.0 };
    try std.testing.expect(!r1.overlaps(r2));
    try std.testing.expect(r1.overlapsWithMargin(r2, 3.0));
}

test "Rect expand" {
    const r = Rect{ .x1 = 10.0, .y1 = 10.0, .x2 = 20.0, .y2 = 20.0 };
    const expanded = r.expand(5.0);
    try std.testing.expectEqual(@as(f32, 5.0), expanded.x1);
    try std.testing.expectEqual(@as(f32, 5.0), expanded.y1);
    try std.testing.expectEqual(@as(f32, 25.0), expanded.x2);
    try std.testing.expectEqual(@as(f32, 25.0), expanded.y2);
}

test "Rect union" {
    const r1 = Rect{ .x1 = 0.0, .y1 = 0.0, .x2 = 10.0, .y2 = 10.0 };
    const r2 = Rect{ .x1 = 5.0, .y1 = 5.0, .x2 = 20.0, .y2 = 20.0 };
    const u = r1.union_(r2);
    try std.testing.expectEqual(@as(f32, 0.0), u.x1);
    try std.testing.expectEqual(@as(f32, 0.0), u.y1);
    try std.testing.expectEqual(@as(f32, 20.0), u.x2);
    try std.testing.expectEqual(@as(f32, 20.0), u.y2);
}

test "Rect containsPoint" {
    const r = Rect{ .x1 = 0.0, .y1 = 0.0, .x2 = 10.0, .y2 = 10.0 };
    try std.testing.expect(r.containsPoint(5.0, 5.0));
    try std.testing.expect(!r.containsPoint(15.0, 5.0));
    try std.testing.expect(!r.containsPoint(5.0, -1.0));
}

test "AnalogGroupType enum values" {
    try std.testing.expectEqual(@as(u8, 0), @intFromEnum(AnalogGroupType.differential));
    try std.testing.expectEqual(@as(u8, 1), @intFromEnum(AnalogGroupType.matched));
    try std.testing.expectEqual(@as(u8, 2), @intFromEnum(AnalogGroupType.shielded));
    try std.testing.expectEqual(@as(u8, 3), @intFromEnum(AnalogGroupType.kelvin));
    try std.testing.expectEqual(@as(u8, 4), @intFromEnum(AnalogGroupType.resistor_matched));
    try std.testing.expectEqual(@as(u8, 5), @intFromEnum(AnalogGroupType.capacitor_array));
}

test "GuardRingType enum values" {
    try std.testing.expectEqual(@as(u8, 0), @intFromEnum(GuardRingType.p_plus));
    try std.testing.expectEqual(@as(u8, 1), @intFromEnum(GuardRingType.n_plus));
    try std.testing.expectEqual(@as(u8, 2), @intFromEnum(GuardRingType.deep_nwell));
    try std.testing.expectEqual(@as(u8, 3), @intFromEnum(GuardRingType.substrate));
}

test "GroupStatus enum values" {
    try std.testing.expectEqual(@as(u8, 0), @intFromEnum(GroupStatus.pending));
    try std.testing.expectEqual(@as(u8, 1), @intFromEnum(GroupStatus.routing));
    try std.testing.expectEqual(@as(u8, 2), @intFromEnum(GroupStatus.routed));
    try std.testing.expectEqual(@as(u8, 3), @intFromEnum(GroupStatus.failed));
}

test "RepairAction enum values" {
    try std.testing.expectEqual(@as(u8, 0), @intFromEnum(RepairAction.none));
    try std.testing.expectEqual(@as(u8, 1), @intFromEnum(RepairAction.adjust_width));
    try std.testing.expectEqual(@as(u8, 2), @intFromEnum(RepairAction.adjust_layer));
    try std.testing.expectEqual(@as(u8, 3), @intFromEnum(RepairAction.add_jog));
    try std.testing.expectEqual(@as(u8, 4), @intFromEnum(RepairAction.add_dummy_via));
    try std.testing.expectEqual(@as(u8, 5), @intFromEnum(RepairAction.rebalance_layer));
}

test "RoutingResult enum values" {
    try std.testing.expectEqual(@as(u8, 0), @intFromEnum(RoutingResult.success));
    try std.testing.expectEqual(@as(u8, 1), @intFromEnum(RoutingResult.mismatch_exceeded));
    try std.testing.expectEqual(@as(u8, 2), @intFromEnum(RoutingResult.no_path));
    try std.testing.expectEqual(@as(u8, 3), @intFromEnum(RoutingResult.max_iterations));
}