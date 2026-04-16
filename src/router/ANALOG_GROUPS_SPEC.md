# AnalogGroupDB Specification — Phase 3

## Overview

`AnalogGroupDB` is a Structure-of-Arrays (SoA) table storing analog net group metadata for the analog router. It is part of Phase 3 of the analog router implementation.

## File Location

`src/router/analog_groups.zig`

---

## Struct Layouts

### ID Types

```zig
pub const AnalogGroupIdx = enum(u32) { _, ... };  // 4 bytes
pub const SegmentIdx    = enum(u32) { _, ... };  // 4 bytes
pub const ShieldIdx     = enum(u32) { _, ... };  // 4 bytes
pub const GuardRingIdx  = enum(u16) { _, ... };  // 2 bytes
pub const ThermalCellIdx = enum(u32) { _, ... }; // 4 bytes
pub const CentroidPatternIdx = enum(u32) { _, ... }; // 4 bytes
```

### Enums

```zig
pub const AnalogGroupType = enum(u8) {
    differential,      // 2 nets, mirrored routing
    matched,           // N nets (>=2), same R/C/length/vias
    shielded,          // 1 net + shield net
    kelvin,            // 2 nets + force_net + sense_net
    resistor_matched,   // resistor segments in CC
    capacitor_array,   // unit cap array
};

pub const GroupStatus = enum(u8) {
    pending,
    routing,
    routed,
    failed,
};
```

### AnalogGroupDB SoA Table

```zig
pub const AnalogGroupDB = struct {
    // Hot fields (touched every routing iteration)
    group_type:       []AnalogGroupType,   // 1B
    route_priority:  []u8,                // 1B
    tolerance:       []f32,               // 4B
    preferred_layer:  []?LayerIdx,         // 3B (u16 + null)
    status:          []GroupStatus,        // 1B

    // Net membership (variable-length, flattened)
    // Group i's nets: net_pool[net_range_start[i] .. net_range_start[i]+net_count[i]]
    net_range_start: []u32,   // 4B — offset into net_pool
    net_count:       []u8,    // 1B — number of nets (max 255)
    net_pool:        []NetIdx, // 4B each — flat pool of all net IDs

    // Cold fields (touched only during setup/reporting)
    name_offsets:       []u32,                    // offset into name_bytes
    name_bytes:        []u8,                       // interned group names
    thermal_tolerance: []?f32,                    // null = no thermal constraint
    coupling_tolerance: []?f32,                   // null = use default
    shield_net:        []?NetIdx,                 // null = not shielded
    force_net:         []?NetIdx,                 // null = not kelvin
    sense_net:         []?NetIdx,                 // null = not kelvin
    centroid_pattern:  []?CentroidPatternIdx,     // index into patterns table

    // Bookkeeping
    len:     u32,
    capacity: u32,
    allocator: std.mem.Allocator,
};
```

### AddGroupRequest

```zig
pub const AddGroupRequest = struct {
    name:               []const u8,
    group_type:         AnalogGroupType,
    nets:               []const NetIdx,
    tolerance:          f32,
    preferred_layer:     ?LayerIdx,
    route_priority:     u8,
    // Optional cold fields
    thermal_tolerance:   ?f32,
    coupling_tolerance: ?f32,
    shield_net:         ?NetIdx,
    force_net:          ?NetIdx,
    sense_net:          ?NetIdx,
    centroid_pattern:    ?CentroidPatternIdx,
};
```

### Errors

```zig
pub const AddGroupError = error{
    InvalidNetCount,     // Wrong number of nets for group type
    InvalidTolerance,     // tolerance < 0 or > 1.0
    DeviceTypeMismatch,  // (detected at higher level)
    MissingKelvinNets,   // kelvin group missing force/sense nets
    GroupTableFull,      // No capacity left
};
```

### GroupDependencyGraph

```zig
pub const GroupDependencyGraph = struct {
    adjacency:   []std.ArrayListUnmanaged(AnalogGroupIdx),
    num_groups: u32,
    allocator: std.mem.Allocator,
};

pub fn build(
    allocator:      std.mem.Allocator,
    groups:         *const AnalogGroupDB,
    pin_bboxes:     []const Rect,
    margin:         f32,
) !GroupDependencyGraph

pub fn groupsConflictBetween(
    groups: *const AnalogGroupDB,
    bboxes: []const Rect,
    i: AnalogGroupIdx,
    j: AnalogGroupIdx,
    margin: f32,
) bool
```

### Rect

```zig
pub const Rect = struct {
    x1: f32, y1: f32, x2: f32, y2: f32,

    pub fn overlaps(self: Rect, other: Rect) bool
    pub fn overlapsWithMargin(self: Rect, other: Rect, margin: f32) bool
};
```

---

## Init Signature

```zig
pub fn init(allocator: std.mem.Allocator, capacity: u32) !AnalogGroupDB
```

- Pre-allocates all SoA arrays to `capacity`
- Initializes status of all slots to `.pending`
- Returns error on allocator failure

---

## Public API

| Function | Signature | Description |
|----------|-----------|-------------|
| `init` | `(allocator, capacity) !AnalogGroupDB` | Initialize with pre-allocated capacity |
| `deinit` | `(self: *AnalogGroupDB) void` | Release all memory |
| `addGroup` | `(self: *AnalogGroupDB, req: AddGroupRequest) !void` | Add group with validation |
| `addGroupWithValidation` | `(self: *AnalogGroupDB, req: AddGroupRequest) AddGroupError!void` | Add group, return error on invalid input |
| `netsForGroup` | `(self: *const AnalogGroupDB, idx: u32) []const NetIdx` | Get nets for group by index |
| `sortedByPriority` | `(self: *const AnalogGroupDB, allocator) ![]AnalogGroupIdx` | Return groups sorted by route_priority ascending |

---

## Validation Rules

| Group Type | Required Nets | Additional Validation |
|------------|--------------|----------------------|
| `differential` | exactly 2 | — |
| `matched` | >= 2 | — |
| `shielded` | exactly 1 | — |
| `kelvin` | exactly 2 | `force_net != null` and `sense_net != null` |
| `resistor_matched` | >= 2 | — |
| `capacitor_array` | >= 2 | — |

**Tolerance:** must be `0.0 <= tolerance <= 1.0`

---

## Test Code (from GUIDE_04 §3)

### 3.1 Validation Tests

```zig
test "reject differential group with odd net count" {
    var db = try AnalogGroupDB.init(std.testing.allocator, 8);
    defer db.deinit();
    try std.testing.expectError(error.InvalidNetCount, db.addGroup(.{
        .group_type = .differential,
        .nets = &.{ NetIdx.fromInt(0), NetIdx.fromInt(1), NetIdx.fromInt(2) },
        .tolerance = 0.05,
        .preferred_layer = null, .route_priority = 0,
        .thermal_tolerance = null, .coupling_tolerance = null,
        .shield_net = null, .force_net = null, .sense_net = null,
        .centroid_pattern = null,
    }));
}

test "reject differential group with 0 nets" {
    var db = try AnalogGroupDB.init(std.testing.allocator, 8);
    defer db.deinit();
    try std.testing.expectError(error.InvalidNetCount, db.addGroup(.{
        .group_type = .differential,
        .nets = &.{},
        .tolerance = 0.05,
        .preferred_layer = null, .route_priority = 0,
        .thermal_tolerance = null, .coupling_tolerance = null,
        .shield_net = null, .force_net = null, .sense_net = null,
        .centroid_pattern = null,
    }));
}

test "kelvin group requires force and sense nets" {
    var db = try AnalogGroupDB.init(std.testing.allocator, 8);
    defer db.deinit();
    try std.testing.expectError(error.MissingKelvinNets, db.addGroup(.{
        .group_type = .kelvin,
        .nets = &.{ NetIdx.fromInt(0), NetIdx.fromInt(1) },
        .tolerance = 0.05,
        .preferred_layer = null, .route_priority = 0,
        .thermal_tolerance = null, .coupling_tolerance = null,
        .shield_net = null, .force_net = null, .sense_net = null,
        .centroid_pattern = null,
    }));
}

test "tolerance must be positive" {
    var db = try AnalogGroupDB.init(std.testing.allocator, 8);
    defer db.deinit();
    try std.testing.expectError(error.InvalidTolerance, db.addGroup(.{
        .group_type = .matched,
        .nets = &.{ NetIdx.fromInt(0), NetIdx.fromInt(1) },
        .tolerance = -0.01,
        .preferred_layer = null, .route_priority = 0,
        .thermal_tolerance = null, .coupling_tolerance = null,
        .shield_net = null, .force_net = null, .sense_net = null,
        .centroid_pattern = null,
    }));
}

test "tolerance must be <= 1.0" {
    var db = try AnalogGroupDB.init(std.testing.allocator, 8);
    defer db.deinit();
    try std.testing.expectError(error.InvalidTolerance, db.addGroup(.{
        .group_type = .matched,
        .nets = &.{ NetIdx.fromInt(0), NetIdx.fromInt(1) },
        .tolerance = 1.5,
        .preferred_layer = null, .route_priority = 0,
        .thermal_tolerance = null, .coupling_tolerance = null,
        .shield_net = null, .force_net = null, .sense_net = null,
        .centroid_pattern = null,
    }));
}
```

### 3.2 Priority Ordering Tests

```zig
test "groups sorted by priority for routing order" {
    var db = try AnalogGroupDB.init(std.testing.allocator, 8);
    defer db.deinit();

    try db.addGroup(.{ .name = "grp_a", .group_type = .matched,
        .nets = &.{ NetIdx.fromInt(0), NetIdx.fromInt(1) },
        .tolerance = 0.05, .preferred_layer = null, .route_priority = 2,
        .thermal_tolerance = null, .coupling_tolerance = null,
        .shield_net = null, .force_net = null, .sense_net = null,
        .centroid_pattern = null,
    });
    try db.addGroup(.{ .name = "grp_b", .group_type = .differential,
        .nets = &.{ NetIdx.fromInt(2), NetIdx.fromInt(3) },
        .tolerance = 0.05, .preferred_layer = null, .route_priority = 0,
        .thermal_tolerance = null, .coupling_tolerance = null,
        .shield_net = null, .force_net = null, .sense_net = null,
        .centroid_pattern = null,
    });
    try db.addGroup(.{ .name = "grp_c", .group_type = .shielded,
        .nets = &.{ NetIdx.fromInt(4) },
        .tolerance = 0.05, .preferred_layer = null, .route_priority = 1,
        .thermal_tolerance = null, .coupling_tolerance = null,
        .shield_net = null, .force_net = null, .sense_net = null,
        .centroid_pattern = null,
    });

    const order = try db.sortedByPriority(std.testing.allocator);
    defer std.testing.allocator.free(order);

    // Priority 0 (grp_b) first, then 1 (grp_c), then 2 (grp_a)
    try std.testing.expectEqual(@as(u8, 0), db.route_priority[order[0].toInt()]);
    try std.testing.expectEqual(@as(u8, 1), db.route_priority[order[1].toInt()]);
    try std.testing.expectEqual(@as(u8, 2), db.route_priority[order[2].toInt()]);
}
```

### Additional Tests (GroupDependencyGraph)

```zig
test "GroupDependencyGraph build with no conflicts" {
    var db = try AnalogGroupDB.init(std.testing.allocator, 4);
    defer db.deinit();
    // ... add two groups with disjoint nets and non-overlapping bboxes ...
    const bboxes = [_]Rect{
        .{ .x1 = 0, .y1 = 0, .x2 = 10, .y2 = 10 },
        .{ .x1 = 100, .y1 = 100, .x2 = 110, .y2 = 110 },
    };
    var graph = try GroupDependencyGraph.build(std.testing.allocator, &db, &bboxes, 5.0);
    defer graph.deinit();
    try std.testing.expectEqual(@as(u32, 2), graph.num_groups);
    try std.testing.expectEqual(@as(usize, 0), graph.adjacency[0].items.len);
    try std.testing.expectEqual(@as(usize, 0), graph.adjacency[1].items.len);
}

test "GroupDependencyGraph detects shared net conflict" {
    // ... groups sharing net 1, overlapping bboxes ...
    var graph = try GroupDependencyGraph.build(std.testing.allocator, &db, &bboxes, 5.0);
    defer graph.deinit();
    try std.testing.expectEqual(@as(usize, 1), graph.adjacency[0].items.len);
    try std.testing.expectEqual(AnalogGroupIdx.fromInt(1), graph.adjacency[0].items[0]);
}

test "groupsConflictBetween helper" {
    // ... verify groupsConflictBetween returns false for non-conflicting groups ...
}

test "Rect overlapsWithMargin" {
    const r1 = Rect{ .x1 = 0, .y1 = 0, .x2 = 10, .y2 = 10 };
    const r2 = Rect{ .x1 = 8, .y1 = 8, .x2 = 18, .y2 = 18 };
    try std.testing.expect(r1.overlapsWithMargin(r2, 5.0));
}
```

---

## Compile-Time Assertions

```zig
comptime {
    std.debug.assert(@sizeOf(AnalogGroupIdx) == 4);
    std.debug.assert(@sizeOf(SegmentIdx) == 4);
    std.debug.assert(@sizeOf(ShieldIdx) == 4);
    std.debug.assert(@sizeOf(GuardRingIdx) == 2);
    std.debug.assert(@sizeOf(AnalogGroupType) == 1);
    std.debug.assert(@sizeOf(GroupStatus) == 1);
}
```

---

## Cache Analysis

| Field Group | Bytes/Group | 200 Groups |
|-------------|-------------|------------|
| Hot (type, priority, tolerance, layer, status) | 13 B | 2.6 KB (41 cache lines) |
| Net membership | 9 B + 4B/nets | ~2.5 KB |
| Cold (names, thermal, coupling, kelvin) | ~40 B | 8 KB |
| **Total** | | **~13 KB** |

Hot fields fit in L1 for 200 groups. Cold fields stay in L3/DRAM during routing.

---

## Build Status

- `zig ast-check src/router/analog_groups.zig` — **passes** (no errors)
- `zig build test` — fails due to pre-existing errors in other stub files (analog_db.zig, guard_ring.zig, shield_router.zig, spatial_grid.zig, thermal.zig, placer/cost.zig, lib.zig, e2e_tests.zig)
- `analog_groups.zig` — **zero errors** in compilation output
