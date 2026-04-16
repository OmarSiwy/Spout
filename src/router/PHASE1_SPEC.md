# Phase 1 Spec: Analog Router Core Types + AnalogRouteDB

## Overview

Phase 1 implements the foundational data structures for the analog router: new ID types, enums, small geometry structs, the `AnalogRouteDB` master struct, the `AnalogSegmentDB` SoA table, and the `SpatialGrid`. Tests follow the patterns in `GUIDE_04_TESTING_STRATEGY.md` sections 1-2.

---

## File Inventory

| File | Purpose |
|------|---------|
| `src/core/types.zig` | ADD: AnalogGroupIdx, SegmentIdx, ShieldIdx, GuardRingIdx, ThermalCellIdx |
| `src/router/analog_types.zig` | NEW (~250 lines): ID types (already moved here), enums, geometry structs, compile-time assertions |
| `src/router/analog_db.zig` | NEW (~550 lines): AnalogSegmentDB, AnalogRouteDB, init/deinit/resetPass, MatchReportDB stub |
| `src/router/spatial_grid.zig` | NEW (~550 lines): SpatialGrid, NeighborIterator, SpatialDrcChecker |
| `src/router/analog_tests.zig` | NEW (~300 lines): all Phase 1 tests from GUIDE_04 sections 1-2 |
| `src/router/lib.zig` | MODIFY: add analog_types/analog_db exports |

---

## 1. New ID Types (src/core/types.zig — ADDITIONS ONLY)

Following the existing pattern (DeviceIdx, NetIdx etc.):

```zig
// ─── Analog router IDs ─────────────────────────────────────────────────────

pub const AnalogGroupIdx = enum(u32) {
    _,
    pub inline fn toInt(self: AnalogGroupIdx) u32 { return @intFromEnum(self); }
    pub inline fn fromInt(v: u32) AnalogGroupIdx { return @enumFromInt(v); }
};

pub const SegmentIdx = enum(u32) {
    _,
    pub inline fn toInt(self: SegmentIdx) u32 { return @intFromEnum(self); }
    pub inline fn fromInt(v: u32) SegmentIdx { return @enumFromInt(v); }
};

pub const ShieldIdx = enum(u32) {
    _,
    pub inline fn toInt(self: ShieldIdx) u32 { return @intFromEnum(self); }
    pub inline fn fromInt(v: u32) ShieldIdx { return @enumFromInt(v); }
};

pub const GuardRingIdx = enum(u16) {
    _,
    pub inline fn toInt(self: GuardRingIdx) u16 { return @intFromEnum(self); }
    pub inline fn fromInt(v: u16) GuardRingIdx { return @enumFromInt(v); }
};

pub const ThermalCellIdx = enum(u32) {
    _,
    pub inline fn toInt(self: ThermalCellIdx) u32 { return @intFromEnum(self); }
    pub inline fn fromInt(v: u32) ThermalCellIdx { return @enumFromInt(v); }
};
```

**Comptimer layout assertions** (added to existing test block):
```zig
test "AnalogGroupIdx round-trip" {
    const idx = AnalogGroupIdx.fromInt(42);
    try std.testing.expectEqual(@as(u32, 42), idx.toInt());
}
test "SegmentIdx round-trip" { ... }
test "ShieldIdx round-trip" { ... }
test "GuardRingIdx round-trip" { ... }
test "ThermalCellIdx round-trip" { ... }
```

---

## 2. analog_types.zig — Enums + Geometry Structs

### Enums

```zig
pub const AnalogGroupType = enum(u8) {
    differential,      // 2 nets, mirrored routing
    matched,            // N nets, same R/C/length/vias
    shielded,          // 1 signal net + shield net
    kelvin,            // force + sense nets (4-wire)
    resistor_matched,  // resistor segments in common centroid
    capacitor_array,   // unit cap array routing
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
    adjust_width,
    adjust_layer,
    add_jog,
    add_dummy_via,
    rebalance_layer,
};

pub const RoutingResult = enum(u8) {
    success,
    mismatch_exceeded,
    no_path,
    max_iterations,
};

pub const SymmetryAxis = enum(u8) {
    x,  // horizontal axis (mirror across y)
    y,  // vertical axis (mirror across x)
};
```

### Geometry Structs

```zig
pub const Rect = struct {
    x1: f32, y1: f32, x2: f32, y2: f32,

    pub fn width(self: Rect) f32 { return self.x2 - self.x1; }
    pub fn height(self: Rect) f32 { return self.y2 - self.y1; }
    pub fn area(self: Rect) f32 { return self.width() * self.height(); }
    pub fn centerX(self: Rect) f32 { return (self.x1 + self.x2) * 0.5; }
    pub fn centerY(self: Rect) f32 { return (self.y1 + self.y2) * 0.5; }
    pub fn overlaps(self: Rect, other: Rect) bool { ... }
    pub fn overlapsWithMargin(self: Rect, other: Rect, margin: f32) bool { ... }
    pub fn expand(self: Rect, amount: f32) Rect { ... }
    pub fn union_(self: Rect, other: Rect) Rect { ... }
    pub fn containsPoint(self: Rect, x: f32, y: f32) bool { ... }
};

/// Pin is a named point on a net, used for analog routing targets.
pub const Pin = struct {
    x: f32,
    y: f32,
    net: NetIdx,
    name: []const u8,
};
```

### Comptime Assertions

```zig
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
```

---

## 3. analog_db.zig — AnalogSegmentDB + AnalogRouteDB

### AnalogSegmentDB (SoA Table)

```zig
pub const AnalogSegmentDB = struct {
    // ── Geometry (hot) ──
    x1: []f32, y1: []f32, x2: []f32, y2: []f32,
    width: []f32, layer: []u8, net: []NetIdx,

    // ── Analog metadata (warm) ──
    group: []AnalogGroupIdx,
    segment_flags: []SegmentFlags,  // packed: is_shield, is_dummy_via, is_jog

    // ── PEX cache (cold) ──
    resistance: []f32,
    capacitance: []f32,
    coupling_cap: []f32,

    // ── Bookkeeping ──
    len: u32, capacity: u32, allocator: std.mem.Allocator,

    pub const SegmentFlags = packed struct(u8) {
        is_shield: bool = false,
        is_dummy_via: bool = false,
        is_jog: bool = false,
        _padding: u5 = 0,
    };

    pub fn init(allocator: std.mem.Allocator, cap: u32) !AnalogSegmentDB
    pub fn deinit(self: *AnalogSegmentDB) void
    pub const AppendParams = struct { x1, y1, x2, y2, width, layer, net, group, flags }
    pub fn append(self: *AnalogSegmentDB, p: AppendParams) !void
    pub fn toRouteArrays(self: *const AnalogSegmentDB, out: *RouteArrays) !void
    pub fn removeGroup(self: *AnalogSegmentDB, gid: AnalogGroupIdx) void
    pub fn netLength(self: *const AnalogSegmentDB, net: NetIdx) f32
    pub fn viaCount(self: *const AnalogSegmentDB, net: NetIdx) u32
    fn grow(self: *AnalogSegmentDB) !void
};
```

### MatchReportDB (stub for Phase 9)

```zig
pub const MatchReportDB = struct {
    group: []AnalogGroupIdx,
    passes: []bool,
    r_ratio: []f32,
    c_ratio: []f32,
    length_ratio: []f32,
    via_delta: []i16,
    coupling_delta: []f32,
    len: u32,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, cap: u32) !MatchReportDB
    pub fn deinit(self: *MatchReportDB) void
};
```

### AnalogRouteDB (Master Database)

```zig
pub const AnalogRouteDB = struct {
    segments: AnalogSegmentDB,
    match_reports: MatchReportDB,
    pdk: *const PdkConfig,
    die_bbox: Rect,
    pass_arena: std.heap.ArenaAllocator,
    thread_arenas: []std.heap.ArenaAllocator,
    allocator: std.mem.Allocator,

    pub fn init(
        allocator: std.mem.Allocator,
        pdk: *const PdkConfig,
        die_bbox: Rect,
        num_threads: u8,
    ) !AnalogRouteDB

    pub fn deinit(self: *AnalogRouteDB) void
    pub fn resetPass(self: *AnalogRouteDB) void
};
```

---

## 4. spatial_grid.zig — Uniform 2D Grid

```zig
pub const SpatialGrid = struct {
    cells_x: u32, cells_y: u32, cell_size: f32,
    origin_x: f32, origin_y: f32,
    cell_offsets: []u32,    // cells_x * cells_y
    cell_counts: []u16,     // cells_x * cells_y
    segment_pool: std.ArrayListUnmanaged(SegmentIdx),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, die_bbox: Rect, pdk: *const PdkConfig) !SpatialGrid
    pub fn deinit(self: *SpatialGrid) void
    pub inline fn cellIndex(self: *const SpatialGrid, x: f32, y: f32) u32
    pub fn rebuild(self: *SpatialGrid, x1, y1, x2, y2, count) !void
    pub fn queryNeighborhood(self: *const SpatialGrid, x: f32, y: f32) NeighborIterator
    fn cellCol(self: *const SpatialGrid, x: f32) u32
    fn cellRow(self: *const SpatialGrid, y: f32) u32

    pub const NeighborIterator = struct { ... }
};

/// Spatial-accelerated DRC checker with O(1)+k lookup.
pub const SpatialDrcChecker = struct {
    grid: *const SpatialGrid,
    seg_x1/x2/y1/y2: []const f32,
    seg_width: []const f32,
    seg_layer: []const u8,
    seg_net: []const NetIdx,
    seg_count: u32,
    pdk: *const PdkConfig,

    pub fn checkSpacing(self: *const SpatialDrcChecker, layer, x, y, net) struct { hard_violation: bool, soft_penalty: f32 }
};
```

---

## 5. Tests (analog_tests.zig — Phase 1 sections 1 and 2)

### Section 1.1: ID Type Round-Trips

```zig
test "AnalogGroupIdx round-trip" {
    const idx = AnalogGroupIdx.fromInt(42);
    try std.testing.expectEqual(@as(u32, 42), idx.toInt());
}

test "SegmentIdx round-trip" {
    const idx = SegmentIdx.fromInt(12345);
    try std.testing.expectEqual(@as(u32, 12345), idx.toInt());
}

test "ShieldIdx round-trip" {
    const idx = ShieldIdx.fromInt(0);
    try std.testing.expectEqual(@as(u32, 0), idx.toInt());
}

test "GuardRingIdx round-trip" {
    const idx = GuardRingIdx.fromInt(100);
    try std.testing.expectEqual(@as(u16, 100), idx.toInt());
}

test "ThermalCellIdx round-trip" {
    const idx = ThermalCellIdx.fromInt(999);
    try std.testing.expectEqual(@as(u32, 999), idx.toInt());
}

test "AnalogGroupIdx boundary values" {
    try std.testing.expectEqual(@as(u32, 0), AnalogGroupIdx.fromInt(0).toInt());
    try std.testing.expectEqual(@as(u32, 0xFFFFFFFF), AnalogGroupIdx.fromInt(0xFFFFFFFF).toInt());
}

test "SegmentIdx and AnalogGroupIdx are distinct types" {
    const S = struct {
        fn takesSegment(_: SegmentIdx) void {}
    };
    S.takesSegment(SegmentIdx.fromInt(0)); // must compile
    // S.takesSegment(AnalogGroupIdx.fromInt(0)); // must NOT compile
}
```

### Section 1.2: Rect Geometry

```zig
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
}
```

### Section 1.3: AnalogSegmentDB CRUD

```zig
test "AnalogSegmentDB init and deinit" {
    var db = try AnalogSegmentDB.init(std.testing.allocator, 64);
    defer db.deinit();
    try std.testing.expectEqual(@as(u32, 0), db.len);
    try std.testing.expectEqual(@as(u32, 64), db.capacity);
}

test "AnalogSegmentDB append segment" {
    var db = try AnalogSegmentDB.init(std.testing.allocator, 8);
    defer db.deinit();

    try db.append(.{
        .x1 = 0.0, .y1 = 0.0, .x2 = 10.0, .y2 = 0.0,
        .width = 0.14, .layer = 1, .net = NetIdx.fromInt(3),
        .group = AnalogGroupIdx.fromInt(0),
        .flags = .{ .is_shield = false, .is_dummy_via = false, .is_jog = false },
    });

    try std.testing.expectEqual(@as(u32, 1), db.len);
    try std.testing.expectEqual(@as(f32, 10.0), db.x2[0]);
    try std.testing.expectEqual(@as(u8, 1), db.layer[0]);
}

test "AnalogSegmentDB append auto-grows" {
    var db = try AnalogSegmentDB.init(std.testing.allocator, 2);
    defer db.deinit();

    for (0..5) |i| {
        try db.append(.{
            .x1 = @floatFromInt(i), .y1 = 0.0,
            .x2 = @floatFromInt(i + 1), .y2 = 0.0,
            .width = 0.14, .layer = 1, .net = NetIdx.fromInt(0),
            .group = AnalogGroupIdx.fromInt(0),
        });
    }
    try std.testing.expectEqual(@as(u32, 5), db.len);
    try std.testing.expect(db.capacity >= 5);
}

test "AnalogSegmentDB toRouteArrays" {
    var db = try AnalogSegmentDB.init(std.testing.allocator, 0);
    defer db.deinit();

    try db.append(.{
        .x1 = 0.0, .y1 = 0.0, .x2 = 10.0, .y2 = 0.0,
        .width = 0.14, .layer = 1, .net = NetIdx.fromInt(3),
        .group = AnalogGroupIdx.fromInt(0),
    });

    var ra = try RouteArrays.init(std.testing.allocator, 0);
    defer ra.deinit();

    try db.toRouteArrays(&ra);
    try std.testing.expectEqual(@as(u32, 1), ra.len);
    try std.testing.expectEqual(@as(f32, 10.0), ra.x2[0]);
}

test "AnalogSegmentDB removeGroup" {
    var db = try AnalogSegmentDB.init(std.testing.allocator, 100);
    defer db.deinit();

    // Add 50 segments for group A, 50 for group B
    for (0..50) |_| {
        try db.append(.{ .x1 = 0.0, .y1 = 0.0, .x2 = 1.0, .y2 = 0.0,
            .width = 0.14, .layer = 1, .net = NetIdx.fromInt(0),
            .group = AnalogGroupIdx.fromInt(0) });
    }
    for (50..100) |_| {
        try db.append(.{ .x1 = 0.0, .y1 = 0.0, .x2 = 1.0, .y2 = 0.0,
            .width = 0.14, .layer = 1, .net = NetIdx.fromInt(1),
            .group = AnalogGroupIdx.fromInt(1) });
    }

    db.removeGroup(AnalogGroupIdx.fromInt(0));
    try std.testing.expectEqual(@as(u32, 50), db.len);
    // Verify group 1 segments remain (all have group=1, net=1)
    try std.testing.expectEqual(NetIdx.fromInt(1), db.net[0]);
}

test "AnalogSegmentDB netLength" {
    var db = try AnalogSegmentDB.init(std.testing.allocator, 0);
    defer db.deinit();

    // Two segments on net 5: lengths 10 and 5 = 15 total
    try db.append(.{ .x1 = 0.0, .y1 = 0.0, .x2 = 10.0, .y2 = 0.0,
        .width = 0.14, .layer = 1, .net = NetIdx.fromInt(5),
        .group = AnalogGroupIdx.fromInt(0) });
    try db.append(.{ .x1 = 10.0, .y1 = 0.0, .x2 = 10.0, .y2 = 5.0,
        .width = 0.14, .layer = 1, .net = NetIdx.fromInt(5),
        .group = AnalogGroupIdx.fromInt(0) });

    const len = db.netLength(NetIdx.fromInt(5));
    try std.testing.expectEqual(@as(f32, 15.0), len);
}

test "AnalogSegmentDB viaCount" {
    var db = try AnalogSegmentDB.init(std.testing.allocator, 0);
    defer db.deinit();

    // 3 zero-length segments (vias) on net 3, plus 2 normal segments
    for (0..3) |_| {
        try db.append(.{ .x1 = 5.0, .y1 = 5.0, .x2 = 5.0, .y2 = 5.0,
            .width = 0.14, .layer = 1, .net = NetIdx.fromInt(3),
            .group = AnalogGroupIdx.fromInt(0) });
    }
    for (0..2) |_| {
        try db.append(.{ .x1 = 0.0, .y1 = 0.0, .x2 = 10.0, .y2 = 0.0,
            .width = 0.14, .layer = 1, .net = NetIdx.fromInt(3),
            .group = AnalogGroupIdx.fromInt(0) });
    }

    try std.testing.expectEqual(@as(u32, 3), db.viaCount(NetIdx.fromInt(3)));
}
```

### Section 1.4: SpatialGrid

```zig
test "SpatialGrid init and deinit" {
    const die_bbox = Rect{ .x1 = 0.0, .y1 = 0.0, .x2 = 100.0, .y2 = 100.0 };
    const pdk = PdkConfig.loadDefault(.sky130);
    var grid = try SpatialGrid.init(std.testing.allocator, die_bbox, &pdk);
    defer grid.deinit();
    try std.testing.expect(grid.cells_x > 0);
    try std.testing.expect(grid.cells_y > 0);
}

test "SpatialGrid cellIndex basic" {
    const die_bbox = Rect{ .x1 = 0.0, .y1 = 0.0, .x2 = 100.0, .y2 = 100.0 };
    const pdk = PdkConfig.loadDefault(.sky130);
    var grid = try SpatialGrid.init(std.testing.allocator, die_bbox, &pdk);
    defer grid.deinit();

    // At origin
    const idx0 = grid.cellIndex(0.0, 0.0);
    try std.testing.expectEqual(@as(u32, 0), idx0);

    // Move 1 cell right
    const idx1 = grid.cellIndex(grid.cell_size, 0.0);
    try std.testing.expectEqual(@as(u32, 1), idx1);
}

test "SpatialGrid cellIndex clamps out-of-bounds" {
    const die_bbox = Rect{ .x1 = 0.0, .y1 = 0.0, .x2 = 100.0, .y2 = 100.0 };
    const pdk = PdkConfig.loadDefault(.sky130);
    var grid = try SpatialGrid.init(std.testing.allocator, die_bbox, &pdk);
    defer grid.deinit();

    // Negative coords clamp to 0
    const idx_neg = grid.cellIndex(-50.0, -50.0);
    try std.testing.expectEqual(@as(u32, 0), idx_neg);

    // Beyond max clamps to last cell
    const idx_big = grid.cellIndex(999.0, 999.0);
    try std.testing.expect(idx_big < grid.cells_x * grid.cells_y);
}

test "SpatialGrid rebuild preserves all segments" {
    const die_bbox = Rect{ .x1 = 0.0, .y1 = 0.0, .x2 = 100.0, .y2 = 100.0 };
    const pdk = PdkConfig.loadDefault(.sky130);
    var grid = try SpatialGrid.init(std.testing.allocator, die_bbox, &pdk);
    defer grid.deinit();

    // Insert 100 segments along diagonal
    var x1s = try std.testing.allocator.alloc(f32, 100);
    var y1s = try std.testing.allocator.alloc(f32, 100);
    var x2s = try std.testing.allocator.alloc(f32, 100);
    var y2s = try std.testing.allocator.alloc(f32, 100);
    defer {
        std.testing.allocator.free(x1s);
        std.testing.allocator.free(y1s);
        std.testing.allocator.free(x2s);
        std.testing.allocator.free(y2s);
    }

    for (0..100) |i| {
        x1s[i] = @floatFromInt(i);
        y1s[i] = 0.0;
        x2s[i] = @floatFromInt(i + 1);
        y2s[i] = 0.0;
    }

    try grid.rebuild(x1s, y1s, x2s, y2s, 100);

    // Verify all are findable
    for (0..100) |i| {
        var found = false;
        var iter = grid.queryNeighborhood(@floatFromInt(i) + 0.5, 0.0);
        while (iter.next()) |seg_idx| {
            if (seg_idx.toInt() == i) found = true;
        }
        try std.testing.expect(found);
    }
}

test "SpatialGrid empty query returns nothing" {
    const die_bbox = Rect{ .x1 = 0.0, .y1 = 0.0, .x2 = 100.0, .y2 = 100.0 };
    const pdk = PdkConfig.loadDefault(.sky130);
    var grid = try SpatialGrid.init(std.testing.allocator, die_bbox, &pdk);
    defer grid.deinit();

    var iter = grid.queryNeighborhood(50.0, 50.0);
    try std.testing.expectEqual(@as(?SegmentIdx, null), iter.next());
}

test "SpatialGrid query finds segment at exact coordinate" {
    const die_bbox = Rect{ .x1 = 0.0, .y1 = 0.0, .x2 = 100.0, .y2 = 100.0 };
    const pdk = PdkConfig.loadDefault(.sky130);
    var grid = try SpatialGrid.init(std.testing.allocator, die_bbox, &pdk);
    defer grid.deinit();

    var x1s = try std.testing.allocator.alloc(f32, 1);
    var y1s = try std.testing.allocator.alloc(f32, 1);
    var x2s = try std.testing.allocator.alloc(f32, 1);
    var y2s = try std.testing.allocator.alloc(f32, 1);
    defer {
        std.testing.allocator.free(x1s);
        std.testing.allocator.free(y1s);
        std.testing.allocator.free(x2s);
        std.testing.allocator.free(y2s);
    }

    x1s[0] = 15.0; y1s[0] = 15.0; x2s[0] = 35.0; y2s[0] = 15.0;
    try grid.rebuild(x1s, y1s, x2s, y2s, 1);

    var found = false;
    var iter = grid.queryNeighborhood(25.0, 15.0);
    while (iter.next()) |seg_idx| {
        if (seg_idx.toInt() == 0) found = true;
    }
    try std.testing.expect(found);
}
```

### Section 1.5: Layout Assertions

```zig
test "layout size assertions" {
    comptime {
        std.debug.assert(@sizeOf(AnalogGroupIdx) == 4);
        std.debug.assert(@sizeOf(SegmentIdx) == 4);
        std.debug.assert(@sizeOf(ShieldIdx) == 4);
        std.debug.assert(@sizeOf(GuardRingIdx) == 2);
        std.debug.assert(@sizeOf(AnalogGroupType) == 1);
        std.debug.assert(@sizeOf(GuardRingType) == 1);
        std.debug.assert(@sizeOf(GroupStatus) == 1);
    }
}
```

---

## 6. Exit Criteria

1. `zig build test` passes with zero errors
2. All new ID types have round-trip tests passing
3. `AnalogSegmentDB.append` grows capacity correctly
4. `AnalogSegmentDB.toRouteArrays` preserves all geometry data (lossless)
5. `AnalogSegmentDB.removeGroup` correctly filters segments
6. `SpatialGrid.cellIndex` never panics on any f32 coordinate (clamp behavior)
7. `SpatialGrid.rebuild` with 100 segments: all segments findable via `queryNeighborhood`
8. `AnalogRouteDB.init/deinit` cycle: no memory leaks under `std.testing.allocator`
9. All 5 new ID types are distinct from existing `NetIdx`/`DeviceIdx` types (compile-time type safety)
10. Comptime layout assertions on all ID and enum sizes pass