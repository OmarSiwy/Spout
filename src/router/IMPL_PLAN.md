# Analog Router — Complete Implementation Plan

**Target:** Zig 0.15 · SKY130 PDK · DOD-first
**Priority:** Accuracy > Performance
**Build:** `nix develop --command zig build test`

---

## Table of Contents

1. [Conventions & Invariants](#1-conventions--invariants)
2. [Phase 1: Core Types + AnalogRouteDB](#2-phase-1-core-types--analogroutedb)
3. [Phase 2: Spatial Grid](#3-phase-2-spatial-grid)
4. [Phase 3: Analog Group Database](#4-phase-3-analog-group-database)
5. [Phase 4: Matched Router](#5-phase-4-matched-router)
6. [Phase 5: Shield Router](#6-phase-5-shield-router)
7. [Phase 6: Guard Ring Inserter](#7-phase-6-guard-ring-inserter)
8. [Phase 7: Thermal Router](#8-phase-7-thermal-router)
9. [Phase 8: LDE Router](#9-phase-8-lde-router)
10. [Phase 9: PEX Feedback Loop](#10-phase-9-pex-feedback-loop)
11. [Phase 10: Thread Pool + Parallel Dispatch](#11-phase-10-thread-pool--parallel-dispatch)
12. [Phase 11: Integration + Signoff](#12-phase-11-integration--signoff)
13. [File Map](#13-file-map)
14. [Dependency Graph](#14-dependency-graph)
15. [Decision Log](#15-decision-log)

---

## 1. Conventions & Invariants

### Layer Index Convention (from `route_arrays.zig`)

```
Route layer: 0=LI, 1=M1, 2=M2, 3=M3, 4=M4, 5=M5
PDK arrays:  0=M1, 1=M2, ...  (0-indexed from M1)
Grid layers: 0=M1, 1=M2, ...  (same as PDK)

Conversion: pdk_index = route_layer - 1  (for route_layer >= 1)
            route_layer = grid_layer + 1
```

This convention is used in `detailed.zig:44` (`pdkIndex`), `detailed.zig:395` (`routeLayer = a.layer + 1`), and `route_arrays.zig` header comment. All new code MUST follow it.

### Existing ID Types (from `src/core/types.zig`)

```zig
DeviceIdx  = enum(u32)   // line 10
NetIdx     = enum(u32)   // line 16
PinIdx     = enum(u32)   // line 22
ConstraintIdx = enum(u32) // line 28
LayerIdx   = enum(u16)   // line 34
PolygonIdx = enum(u32)   // line 40
EdgeIdx    = enum(u32)   // line 46
```

All use `toInt()`/`fromInt()` inline methods. New analog IDs follow same pattern.

### Existing Route Storage (from `src/core/route_arrays.zig`)

```zig
RouteArrays = struct {
    layer: []u8, x1/y1/x2/y2: []f32, width: []f32, net: []NetIdx,
    len: u32, capacity: u32, allocator
    fn append(layer, x1, y1, x2, y2, width, net) !void
    fn growTo(new_cap) !void
    fn deinit() void
}
```

Analog router output MUST be convertible to RouteArrays via `@memcpy` of matching columns.

### Existing A* Interface (from `src/router/astar.zig`)

```zig
AStarRouter = struct {
    via_cost: f32 = 3.0,
    congestion_weight: f32 = 0.5,
    wrong_way_cost: f32 = 3.0,
    drc_checker: ?*const InlineDrcChecker,
    drc_weight: f32 = 1.0,
    fn init(allocator) AStarRouter
    fn findPath(*const, grid, source, target, net) !?RoutePath
}
```

Key: `findPath` takes `grid: *const MultiLayerGrid`, returns `?RoutePath` (caller owns nodes slice). 6-neighbor expansion (2 preferred + 2 cross + 2 via). NodeKey = packed u64.

### Existing Steiner Interface (from `src/router/steiner.zig`)

```zig
SteinerTree = struct {
    segments: std.ArrayList(Segment),  // Segment = {x1,y1,x2,y2}
    fn build(allocator, pin_positions: []const [2]f32) !SteinerTree
    fn totalLength() f32
    fn deinit() void
}
```

Uses Prim's MST with 256-point static buffer. 1-Steiner heuristic on Hanan grid. Special cases: 0-1 pins (empty), 2 pins (L-shape), 3 pins (median T-shape).

### Existing Inline DRC (from `src/router/inline_drc.zig`)

```zig
InlineDrcChecker = struct {
    segments: ArrayListUnmanaged(WireRect),
    pdk: *const LayoutPdkConfig,  // NOTE: layout_if.PdkConfig, NOT inline_drc.PdkConfig
    fn init(allocator, pdk, origin_x, origin_y, extent_x, extent_y) !InlineDrcChecker
    fn addSegment(layer, x1, y1, x2, y2, width, net) !void
    fn checkSpacing(layer, x, y, net) DrcResult  // O(n) linear scan
    fn removeSegmentsForNet(net) void
}
```

**Critical limitation:** `checkSpacing` is O(n) over all segments. Phase 2 spatial grid replaces this.

### PdkConfig Key Fields (from `src/core/layout_if.zig`)

```
min_spacing[8], same_net_spacing[8], min_width[8], via_width[8],
min_enclosure[8], min_area[8], width_threshold[8], wide_spacing[8],
via_spacing[8], metal_pitch[8], metal_direction[8], metal_thickness[8],
wire_thickness[8], dielectric_thickness[8], j_max[8],
guard_ring_width: f32, guard_ring_spacing: f32,
li_min_spacing, li_min_width, li_min_area,
db_unit: f32, num_metal_layers: u8
```

SKY130 values: `num_metal_layers=5`, `min_spacing[0]=0.14` (M1), `min_width[0]=0.14`, `db_unit=0.001`.

### DOD Rules

1. **SoA via separate slices** — not MultiArrayList (too much ceremony for manual column access).
2. **Opaque enum IDs** — compile-time type safety, zero cost.
3. **Hot/cold split** — hot fields (geometry, dispatch keys) separate from cold (names, debug).
4. **Existence tables** — membership in table = boolean condition. No `is_X: bool` in hot loops.
5. **Arena allocation** — per-pass scratch, per-thread working memory. Reset, not free.
6. **Flat arrays indexed by ID** — no HashMap for dense sequential keys.

### Error Handling Convention

All functions that allocate return `!T`. Routing failures that are recoverable (no path found, DRC conflict during shield placement) are handled by status fields on the group, NOT by returning errors up the stack. Only OOM and true invariant violations propagate as errors.

---

## 2. Phase 1: Core Types + AnalogRouteDB

### 2.1 New File: `src/router/analog_types.zig` (~200 lines)

```zig
const std = @import("std");
const core_types = @import("../core/types.zig");
pub const NetIdx = core_types.NetIdx;
pub const DeviceIdx = core_types.DeviceIdx;
pub const LayerIdx = core_types.LayerIdx;

// ── New ID Types ──

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

// ── Enums ──

pub const AnalogGroupType = enum(u8) {
    differential,      // 2 nets, mirrored routing
    matched,           // N nets, same R/C/length/vias
    shielded,          // 1 signal net + 1 shield net
    kelvin,            // force + sense nets (4-wire)
    resistor_matched,  // resistor segments in common centroid
    capacitor_array,   // unit cap array routing
};

pub const GroupStatus = enum(u8) {
    pending,
    routing,
    routed,
    failed,
};

pub const RepairAction = enum(u8) {
    none,
    adjust_width,     // R mismatch → widen/narrow
    adjust_layer,     // C mismatch → move to different layer
    add_jog,          // length mismatch → serpentine
    add_dummy_via,    // via count mismatch → insert dummy
    rebalance_layer,  // coupling mismatch → reassign layers
};

pub const RoutingResult = enum(u8) {
    success,
    mismatch_exceeded,  // converged but above tolerance
    no_path,            // A* found no route
    max_iterations,     // PEX loop exhausted
};

// ── Geometry ──

pub const Rect = struct {
    x1: f32,
    y1: f32,
    x2: f32,
    y2: f32,

    pub fn width(self: Rect) f32 { return self.x2 - self.x1; }
    pub fn height(self: Rect) f32 { return self.y2 - self.y1; }
    pub fn area(self: Rect) f32 { return self.width() * self.height(); }
    pub fn centerX(self: Rect) f32 { return (self.x1 + self.x2) * 0.5; }
    pub fn centerY(self: Rect) f32 { return (self.y1 + self.y2) * 0.5; }

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
};

pub const SymmetryAxis = enum(u8) {
    x,  // horizontal axis (mirror across y)
    y,  // vertical axis (mirror across x)
};

// ── Compile-time assertions ──

comptime {
    std.debug.assert(@sizeOf(AnalogGroupIdx) == 4);
    std.debug.assert(@sizeOf(SegmentIdx) == 4);
    std.debug.assert(@sizeOf(ShieldIdx) == 4);
    std.debug.assert(@sizeOf(GuardRingIdx) == 2);
    std.debug.assert(@sizeOf(ThermalCellIdx) == 4);
    std.debug.assert(@sizeOf(AnalogGroupType) == 1);
    std.debug.assert(@sizeOf(GroupStatus) == 1);
    std.debug.assert(@sizeOf(RepairAction) == 1);
}
```

### 2.2 New File: `src/router/analog_db.zig` (~400 lines)

The master database owns all SoA tables and arenas.

```zig
const std = @import("std");
const at = @import("analog_types.zig");
const layout_if = @import("../core/layout_if.zig");
const route_arrays_mod = @import("../core/route_arrays.zig");

const Rect = at.Rect;
const AnalogGroupIdx = at.AnalogGroupIdx;
const SegmentIdx = at.SegmentIdx;
const NetIdx = at.NetIdx;
const PdkConfig = layout_if.PdkConfig;
const RouteArrays = route_arrays_mod.RouteArrays;

// Forward-declare sub-table types (from their respective files).
// These are imported once the files exist.
// pub const AnalogGroupDB = @import("analog_groups.zig").AnalogGroupDB;
// pub const SpatialGrid = @import("spatial_grid.zig").SpatialGrid;
// ... etc.

/// SoA segment storage for analog-routed wires.
/// Geometry columns match RouteArrays for zero-copy output.
pub const AnalogSegmentDB = struct {
    // ── Geometry (hot) ──
    x1: []f32,
    y1: []f32,
    x2: []f32,
    y2: []f32,
    width: []f32,
    layer: []u8,
    net: []NetIdx,

    // ── Analog metadata (warm) ──
    group: []AnalogGroupIdx,
    segment_flags: []SegmentFlags,  // packed instead of 3 separate bools

    // ── PEX cache (cold) ──
    resistance: []f32,
    capacitance: []f32,
    coupling_cap: []f32,

    // ── Bookkeeping ──
    len: u32,
    capacity: u32,
    allocator: std.mem.Allocator,

    pub const SegmentFlags = packed struct(u8) {
        is_shield: bool = false,
        is_dummy_via: bool = false,
        is_jog: bool = false,
        _padding: u5 = 0,
    };

    pub fn init(allocator: std.mem.Allocator, cap: u32) !AnalogSegmentDB {
        const n: usize = @intCast(cap);
        return .{
            .x1 = try allocator.alloc(f32, n),
            .y1 = try allocator.alloc(f32, n),
            .x2 = try allocator.alloc(f32, n),
            .y2 = try allocator.alloc(f32, n),
            .width = try allocator.alloc(f32, n),
            .layer = try allocator.alloc(u8, n),
            .net = try allocator.alloc(NetIdx, n),
            .group = try allocator.alloc(AnalogGroupIdx, n),
            .segment_flags = try allocator.alloc(SegmentFlags, n),
            .resistance = try allocator.alloc(f32, n),
            .capacitance = try allocator.alloc(f32, n),
            .coupling_cap = try allocator.alloc(f32, n),
            .len = 0,
            .capacity = cap,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *AnalogSegmentDB) void {
        if (self.capacity == 0) return;
        self.allocator.free(self.x1);
        self.allocator.free(self.y1);
        self.allocator.free(self.x2);
        self.allocator.free(self.y2);
        self.allocator.free(self.width);
        self.allocator.free(self.layer);
        self.allocator.free(self.net);
        self.allocator.free(self.group);
        self.allocator.free(self.segment_flags);
        self.allocator.free(self.resistance);
        self.allocator.free(self.capacitance);
        self.allocator.free(self.coupling_cap);
    }

    pub const AppendParams = struct {
        x1: f32, y1: f32, x2: f32, y2: f32,
        width: f32, layer: u8, net: NetIdx,
        group: AnalogGroupIdx,
        flags: SegmentFlags = .{},
    };

    pub fn append(self: *AnalogSegmentDB, p: AppendParams) !void {
        if (self.len >= self.capacity) {
            try self.grow();
        }
        const i: usize = @intCast(self.len);
        self.x1[i] = p.x1;
        self.y1[i] = p.y1;
        self.x2[i] = p.x2;
        self.y2[i] = p.y2;
        self.width[i] = p.width;
        self.layer[i] = p.layer;
        self.net[i] = p.net;
        self.group[i] = p.group;
        self.segment_flags[i] = p.flags;
        self.resistance[i] = 0.0;
        self.capacitance[i] = 0.0;
        self.coupling_cap[i] = 0.0;
        self.len += 1;
    }

    fn grow(self: *AnalogSegmentDB) !void {
        const new_cap = if (self.capacity == 0) @as(u32, 256) else self.capacity * 2;
        const n: usize = @intCast(new_cap);
        self.x1 = try self.allocator.realloc(self.x1, n);
        self.y1 = try self.allocator.realloc(self.y1, n);
        self.x2 = try self.allocator.realloc(self.x2, n);
        self.y2 = try self.allocator.realloc(self.y2, n);
        self.width = try self.allocator.realloc(self.width, n);
        self.layer = try self.allocator.realloc(self.layer, n);
        self.net = try self.allocator.realloc(self.net, n);
        self.group = try self.allocator.realloc(self.group, n);
        self.segment_flags = try self.allocator.realloc(self.segment_flags, n);
        self.resistance = try self.allocator.realloc(self.resistance, n);
        self.capacitance = try self.allocator.realloc(self.capacitance, n);
        self.coupling_cap = try self.allocator.realloc(self.coupling_cap, n);
        self.capacity = new_cap;
    }

    /// Copy geometry columns to RouteArrays. Direct @memcpy — zero conversion.
    pub fn toRouteArrays(self: *const AnalogSegmentDB, out: *RouteArrays) !void {
        const n: usize = @intCast(self.len);
        if (n == 0) return;
        const needed = out.len + @as(u32, @intCast(n));
        if (needed > out.capacity) try out.growTo(needed);
        const base: usize = @intCast(out.len);
        @memcpy(out.layer[base..][0..n], self.layer[0..n]);
        @memcpy(out.x1[base..][0..n], self.x1[0..n]);
        @memcpy(out.y1[base..][0..n], self.y1[0..n]);
        @memcpy(out.x2[base..][0..n], self.x2[0..n]);
        @memcpy(out.y2[base..][0..n], self.y2[0..n]);
        @memcpy(out.width[base..][0..n], self.width[0..n]);
        @memcpy(out.net[base..][0..n], self.net[0..n]);
        out.len = needed;
    }

    /// Remove all segments belonging to a group (for rip-up).
    pub fn removeGroup(self: *AnalogSegmentDB, gid: AnalogGroupIdx) void {
        var write: u32 = 0;
        const len: usize = @intCast(self.len);
        for (0..len) |read| {
            if (self.group[read].toInt() != gid.toInt()) {
                if (write != read) {
                    self.x1[write] = self.x1[read];
                    self.y1[write] = self.y1[read];
                    self.x2[write] = self.x2[read];
                    self.y2[write] = self.y2[read];
                    self.width[write] = self.width[read];
                    self.layer[write] = self.layer[read];
                    self.net[write] = self.net[read];
                    self.group[write] = self.group[read];
                    self.segment_flags[write] = self.segment_flags[read];
                    self.resistance[write] = self.resistance[read];
                    self.capacitance[write] = self.capacitance[read];
                    self.coupling_cap[write] = self.coupling_cap[read];
                }
                write += 1;
            }
        }
        self.len = write;
    }

    /// Total wire length of segments belonging to a net.
    pub fn netLength(self: *const AnalogSegmentDB, net: NetIdx) f32 {
        var total: f32 = 0.0;
        const len: usize = @intCast(self.len);
        for (0..len) |i| {
            if (self.net[i].toInt() == net.toInt()) {
                total += @abs(self.x2[i] - self.x1[i]) + @abs(self.y2[i] - self.y1[i]);
            }
        }
        return total;
    }

    /// Count vias for a net (zero-length segments = vias).
    pub fn viaCount(self: *const AnalogSegmentDB, net: NetIdx) u32 {
        var count: u32 = 0;
        const len: usize = @intCast(self.len);
        for (0..len) |i| {
            if (self.net[i].toInt() == net.toInt()) {
                if (self.x1[i] == self.x2[i] and self.y1[i] == self.y2[i]) count += 1;
            }
        }
        return count;
    }
};

/// The master database. Owns all analog routing state.
pub const AnalogRouteDB = struct {
    // Owned tables (initialized in later phases, stored as optionals until then)
    segments: AnalogSegmentDB,
    // groups: AnalogGroupDB,       // Phase 3
    // spatial: SpatialGrid,        // Phase 2
    // shields: ShieldDB,           // Phase 5
    // guard_rings: GuardRingDB,    // Phase 6
    // thermal: ?ThermalMap,        // Phase 7
    // lde: LDEConstraintDB,       // Phase 8
    // match_reports: MatchReportDB, // Phase 9

    // Shared references
    pdk: *const PdkConfig,
    die_bbox: Rect,

    // Arenas
    pass_arena: std.heap.ArenaAllocator,
    thread_arenas: []std.heap.ArenaAllocator,

    allocator: std.mem.Allocator,

    pub fn init(
        allocator: std.mem.Allocator,
        pdk: *const PdkConfig,
        die_bbox: Rect,
        num_threads: u8,
    ) !AnalogRouteDB {
        const nt: usize = @intCast(@max(num_threads, 1));
        var thread_arenas = try allocator.alloc(std.heap.ArenaAllocator, nt);
        for (thread_arenas) |*ta| {
            ta.* = std.heap.ArenaAllocator.init(allocator);
        }
        return .{
            .segments = try AnalogSegmentDB.init(allocator, 4096),
            .pdk = pdk,
            .die_bbox = die_bbox,
            .pass_arena = std.heap.ArenaAllocator.init(allocator),
            .thread_arenas = thread_arenas,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *AnalogRouteDB) void {
        for (self.thread_arenas) |*ta| ta.deinit();
        self.allocator.free(self.thread_arenas);
        self.pass_arena.deinit();
        self.segments.deinit();
    }

    /// Reset scratch between PEX iterations.
    pub fn resetPass(self: *AnalogRouteDB) void {
        _ = self.pass_arena.reset(.retain_capacity);
        for (self.thread_arenas) |*ta| {
            _ = ta.reset(.retain_capacity);
        }
    }
};
```

### 2.3 Modifications

**`src/core/types.zig`** — Do NOT add analog IDs here. Keep them in `analog_types.zig` to avoid coupling the core types module to the analog router. The existing types module is imported by many subsystems; analog IDs are router-internal.

**`src/router/lib.zig`** — Add at bottom:

```zig
pub const analog_types = @import("analog_types.zig");
pub const analog_db = @import("analog_db.zig");
pub const AnalogRouteDB = analog_db.AnalogRouteDB;
pub const AnalogSegmentDB = analog_db.AnalogSegmentDB;
```

And in the `test` block:

```zig
_ = @import("analog_types.zig");
_ = @import("analog_db.zig");
```

### 2.4 Exit Criteria

- `zig build test` passes, zero leaks under `std.testing.allocator`
- `AnalogSegmentDB`: append 100 segments, verify `toRouteArrays` produces identical geometry
- `AnalogRouteDB`: init + deinit cycle with 4 thread arenas, no leaks
- `removeGroup`: insert 50 segments for group A and 50 for group B, remove A, verify 50 remain
- Compile-time assertions on all ID sizes pass

---

## 3. Phase 2: Spatial Grid

### 3.1 New File: `src/router/spatial_grid.zig` (~500 lines)

Replaces the O(n) linear scan in `inline_drc.zig:187-224` with O(1) cell lookup + 9-cell neighborhood.

**Design decisions:**
- Uniform grid, NOT R-tree. Cell count known at init. O(1) lookup. No pointer chasing.
- `cell_size = 2 * max(min_spacing[0..num_metal_layers])`. For SKY130: `2 * 0.28 = 0.56 µm` (M2 has max spacing). This guarantees any spacing query touches at most 9 cells.
- Per-cell storage: offset + count into flat `segment_pool`. Rebuilt O(n) between wavefronts.
- Segments spanning multiple cells are inserted into every cell they touch.

```zig
const std = @import("std");
const at = @import("analog_types.zig");
const layout_if = @import("../core/layout_if.zig");

const Rect = at.Rect;
const SegmentIdx = at.SegmentIdx;
const NetIdx = at.NetIdx;
const PdkConfig = layout_if.PdkConfig;

pub const SpatialGrid = struct {
    // Grid geometry
    cells_x: u32,
    cells_y: u32,
    cell_size: f32,
    origin_x: f32,
    origin_y: f32,

    // Per-cell segment index lists (sorted offset/count into pool)
    cell_offsets: []u32,    // [cells_x * cells_y]
    cell_counts: []u16,     // [cells_x * cells_y]
    segment_pool: std.ArrayListUnmanaged(SegmentIdx),

    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, die_bbox: Rect, pdk: *const PdkConfig) !SpatialGrid {
        // Cell size = 2 * max spacing
        var max_sp: f32 = 0.0;
        for (0..pdk.num_metal_layers) |i| {
            max_sp = @max(max_sp, pdk.min_spacing[i]);
        }
        const cell_size = @max(max_sp * 2.0, 0.01); // safety floor

        const w = die_bbox.x2 - die_bbox.x1;
        const h = die_bbox.y2 - die_bbox.y1;
        const cx: u32 = @intFromFloat(@ceil(w / cell_size)) + 1;
        const cy: u32 = @intFromFloat(@ceil(h / cell_size)) + 1;
        const total: usize = @intCast(@as(u64, cx) * @as(u64, cy));

        const offsets = try allocator.alloc(u32, total);
        @memset(offsets, 0);
        const counts = try allocator.alloc(u16, total);
        @memset(counts, 0);

        return .{
            .cells_x = cx,
            .cells_y = cy,
            .cell_size = cell_size,
            .origin_x = die_bbox.x1,
            .origin_y = die_bbox.y1,
            .cell_offsets = offsets,
            .cell_counts = counts,
            .segment_pool = .{},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *SpatialGrid) void {
        self.allocator.free(self.cell_offsets);
        self.allocator.free(self.cell_counts);
        self.segment_pool.deinit(self.allocator);
    }

    /// O(1) cell index from world coordinates. Clamps to grid bounds.
    pub inline fn cellIndex(self: *const SpatialGrid, x: f32, y: f32) u32 {
        const fx = @max(0.0, (x - self.origin_x) / self.cell_size);
        const fy = @max(0.0, (y - self.origin_y) / self.cell_size);
        const cx: u32 = @min(@as(u32, @intFromFloat(fx)), self.cells_x - 1);
        const cy: u32 = @min(@as(u32, @intFromFloat(fy)), self.cells_y - 1);
        return cy * self.cells_x + cx;
    }

    /// Rebuild grid from segment geometry arrays (O(n)).
    /// Called between wavefronts. Clears all cells, then repopulates.
    ///
    /// `x1`, `y1`, `x2`, `y2` are the segment geometry columns from AnalogSegmentDB.
    /// `count` is the number of valid segments.
    pub fn rebuild(
        self: *SpatialGrid,
        x1: []const f32,
        y1: []const f32,
        x2: []const f32,
        y2: []const f32,
        count: u32,
    ) !void {
        // Phase 1: count segments per cell
        @memset(self.cell_counts, 0);
        const n: usize = @intCast(count);

        for (0..n) |i| {
            const min_x = @min(x1[i], x2[i]);
            const max_x = @max(x1[i], x2[i]);
            const min_y = @min(y1[i], y2[i]);
            const max_y = @max(y1[i], y2[i]);

            const cx_lo = self.cellCol(min_x);
            const cx_hi = self.cellCol(max_x);
            const cy_lo = self.cellRow(min_y);
            const cy_hi = self.cellRow(max_y);

            var cy = cy_lo;
            while (cy <= cy_hi) : (cy += 1) {
                var cx = cx_lo;
                while (cx <= cx_hi) : (cx += 1) {
                    const idx = cy * self.cells_x + cx;
                    self.cell_counts[idx] +|= 1;
                }
            }
        }

        // Phase 2: compute offsets (prefix sum)
        var total: u32 = 0;
        const total_cells: usize = @intCast(@as(u64, self.cells_x) * @as(u64, self.cells_y));
        for (0..total_cells) |c| {
            self.cell_offsets[c] = total;
            total += self.cell_counts[c];
        }

        // Phase 3: fill pool
        self.segment_pool.clearRetainingCapacity();
        try self.segment_pool.resize(self.allocator, total);
        // Temp write cursors (reuse cell_counts, reset to 0)
        var write_cursors = try self.allocator.alloc(u32, total_cells);
        defer self.allocator.free(write_cursors);
        @memset(write_cursors, 0);

        for (0..n) |i| {
            const min_x = @min(x1[i], x2[i]);
            const max_x = @max(x1[i], x2[i]);
            const min_y = @min(y1[i], y2[i]);
            const max_y = @max(y1[i], y2[i]);

            const cx_lo = self.cellCol(min_x);
            const cx_hi = self.cellCol(max_x);
            const cy_lo = self.cellRow(min_y);
            const cy_hi = self.cellRow(max_y);

            var cy = cy_lo;
            while (cy <= cy_hi) : (cy += 1) {
                var cx = cx_lo;
                while (cx <= cx_hi) : (cx += 1) {
                    const cell = cy * self.cells_x + cx;
                    const pos = self.cell_offsets[cell] + write_cursors[cell];
                    self.segment_pool.items[pos] = SegmentIdx.fromInt(@intCast(i));
                    write_cursors[cell] += 1;
                }
            }
        }
    }

    /// Query 3x3 neighborhood around (x,y). Returns segment indices.
    /// Caller must do actual geometry check against returned segments.
    pub fn queryNeighborhood(self: *const SpatialGrid, x: f32, y: f32) NeighborIterator {
        const col = self.cellCol(x);
        const row = self.cellRow(y);
        return .{
            .grid = self,
            .center_col = col,
            .center_row = row,
            .dy = 0,
            .dx = 0,
            .seg_idx = 0,
            .started = false,
        };
    }

    pub const NeighborIterator = struct {
        grid: *const SpatialGrid,
        center_col: u32,
        center_row: u32,
        dy: i8,   // -1, 0, +1
        dx: i8,   // -1, 0, +1
        seg_idx: u16,
        started: bool,

        pub fn next(self: *NeighborIterator) ?SegmentIdx {
            if (!self.started) {
                self.dy = -1;
                self.dx = -1;
                self.seg_idx = 0;
                self.started = true;
            }

            while (self.dy <= 1) {
                const r = @as(i64, self.center_row) + self.dy;
                if (r >= 0 and r < self.grid.cells_y) {
                    while (self.dx <= 1) {
                        const c = @as(i64, self.center_col) + self.dx;
                        if (c >= 0 and c < self.grid.cells_x) {
                            const cell: u32 = @intCast(r * @as(i64, self.grid.cells_x) + c);
                            const count = self.grid.cell_counts[cell];
                            if (self.seg_idx < count) {
                                const offset = self.grid.cell_offsets[cell];
                                const result = self.grid.segment_pool.items[offset + self.seg_idx];
                                self.seg_idx += 1;
                                return result;
                            }
                        }
                        self.dx += 1;
                        self.seg_idx = 0;
                    }
                }
                self.dy += 1;
                self.dx = -1;
                self.seg_idx = 0;
            }
            return null;
        }
    };

    // Internal helpers
    fn cellCol(self: *const SpatialGrid, x: f32) u32 {
        const f = @max(0.0, (x - self.origin_x) / self.cell_size);
        return @min(@as(u32, @intFromFloat(f)), self.cells_x - 1);
    }

    fn cellRow(self: *const SpatialGrid, y: f32) u32 {
        const f = @max(0.0, (y - self.origin_y) / self.cell_size);
        return @min(@as(u32, @intFromFloat(f)), self.cells_y - 1);
    }
};

/// Spatial-accelerated DRC checker. Wraps SpatialGrid + AnalogSegmentDB
/// to provide the same `checkSpacing(layer, x, y, net) -> DrcResult` interface
/// as InlineDrcChecker but with O(1)+k instead of O(n).
pub const SpatialDrcChecker = struct {
    grid: *const SpatialGrid,
    seg_x1: []const f32,
    seg_y1: []const f32,
    seg_x2: []const f32,
    seg_y2: []const f32,
    seg_width: []const f32,
    seg_layer: []const u8,
    seg_net: []const NetIdx,
    seg_count: u32,
    pdk: *const PdkConfig,

    /// Same interface as InlineDrcChecker.checkSpacing.
    pub fn checkSpacing(self: *const SpatialDrcChecker, layer: u8, x: f32, y: f32, net: NetIdx) struct { hard_violation: bool, soft_penalty: f32 } {
        const pdk_idx = if (layer >= 1) @as(usize, layer) - 1 else 0;
        const min_sp = if (pdk_idx < 8) self.pdk.min_spacing[pdk_idx] else self.pdk.min_spacing[0];
        const min_w = if (pdk_idx < 8) self.pdk.min_width[pdk_idx] else self.pdk.min_width[0];
        const hw = min_w * 0.5;

        const px_min = x - hw;
        const px_max = x + hw;
        const py_min = y - hw;
        const py_max = y + hw;

        var hard = false;
        var soft: f32 = 0.0;

        var iter = self.grid.queryNeighborhood(x, y);
        while (iter.next()) |seg_idx| {
            const si: usize = seg_idx.toInt();
            if (si >= self.seg_count) continue;
            if (self.seg_layer[si] != layer) continue;
            if (self.seg_net[si].toInt() == net.toInt()) continue;

            // Compute segment bbox
            const s_hw = self.seg_width[si] * 0.5;
            const sx_min = @min(self.seg_x1[si], self.seg_x2[si]) - s_hw;
            const sx_max = @max(self.seg_x1[si], self.seg_x2[si]) + s_hw;
            const sy_min = @min(self.seg_y1[si], self.seg_y2[si]) - s_hw;
            const sy_max = @max(self.seg_y1[si], self.seg_y2[si]) + s_hw;

            const gap_x = @max(px_min - sx_max, sx_min - px_max);
            const gap_y = @max(py_min - sy_max, sy_min - py_max);
            const gap = @max(gap_x, gap_y);

            if (gap < 0 or gap < min_sp) {
                hard = true;
                break;
            } else if (gap < min_sp * 1.5) {
                soft += 1.0;
            }
        }

        return .{ .hard_violation = hard, .soft_penalty = soft };
    }
};
```

### 3.2 Exit Criteria

- `cellIndex` clamps negative and out-of-bounds coordinates (no panic on any f32 input)
- `rebuild` with 10K segments: all segments findable via `queryNeighborhood`
- Segment spanning multiple cells: found from query at any point along its extent
- Empty grid query returns null immediately
- Benchmark: `queryNeighborhood` < 200ns at 10K segments

---

## 4. Phase 3: Analog Group Database

### 4.1 New File: `src/router/analog_groups.zig` (~350 lines)

SoA table of analog net groups with validation.

```zig
const std = @import("std");
const at = @import("analog_types.zig");

const AnalogGroupIdx = at.AnalogGroupIdx;
const AnalogGroupType = at.AnalogGroupType;
const GroupStatus = at.GroupStatus;
const NetIdx = at.NetIdx;
const LayerIdx = at.LayerIdx;
const Rect = at.Rect;

pub const AnalogGroupDB = struct {
    // ── Hot fields ──
    group_type: []AnalogGroupType,
    route_priority: []u8,
    tolerance: []f32,
    preferred_layer: []u8,      // 0 = any, 1+ = route layer
    status: []GroupStatus,

    // ── Net membership (flattened) ──
    net_range_start: []u32,     // offset into net_pool
    net_count: []u8,            // nets per group (max 255)
    net_pool: std.ArrayListUnmanaged(NetIdx),

    // ── Cold fields ──
    name_offsets: []u32,
    name_bytes: std.ArrayListUnmanaged(u8),
    thermal_tolerance: []f32,   // 0 = no constraint
    coupling_tolerance: []f32,  // 0 = use default
    shield_net: []NetIdx,       // NetIdx.fromInt(0xFFFFFFFF) = none
    force_net: []NetIdx,        // 0xFFFFFFFF = none
    sense_net: []NetIdx,        // 0xFFFFFFFF = none

    // ── Bookkeeping ──
    len: u32,
    capacity: u32,
    allocator: std.mem.Allocator,

    const NONE_NET = NetIdx.fromInt(0xFFFFFFFF);

    pub fn init(allocator: std.mem.Allocator, cap: u32) !AnalogGroupDB {
        const n: usize = @intCast(cap);
        return .{
            .group_type = try allocator.alloc(AnalogGroupType, n),
            .route_priority = try allocator.alloc(u8, n),
            .tolerance = try allocator.alloc(f32, n),
            .preferred_layer = try allocator.alloc(u8, n),
            .status = try allocator.alloc(GroupStatus, n),
            .net_range_start = try allocator.alloc(u32, n),
            .net_count = try allocator.alloc(u8, n),
            .net_pool = .{},
            .name_offsets = try allocator.alloc(u32, n),
            .name_bytes = .{},
            .thermal_tolerance = try allocator.alloc(f32, n),
            .coupling_tolerance = try allocator.alloc(f32, n),
            .shield_net = try allocator.alloc(NetIdx, n),
            .force_net = try allocator.alloc(NetIdx, n),
            .sense_net = try allocator.alloc(NetIdx, n),
            .len = 0,
            .capacity = cap,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *AnalogGroupDB) void {
        if (self.capacity == 0) return;
        self.allocator.free(self.group_type);
        self.allocator.free(self.route_priority);
        self.allocator.free(self.tolerance);
        self.allocator.free(self.preferred_layer);
        self.allocator.free(self.status);
        self.allocator.free(self.net_range_start);
        self.allocator.free(self.net_count);
        self.net_pool.deinit(self.allocator);
        self.allocator.free(self.name_offsets);
        self.name_bytes.deinit(self.allocator);
        self.allocator.free(self.thermal_tolerance);
        self.allocator.free(self.coupling_tolerance);
        self.allocator.free(self.shield_net);
        self.allocator.free(self.force_net);
        self.allocator.free(self.sense_net);
    }

    pub const AddGroupParams = struct {
        name: []const u8 = "",
        group_type: AnalogGroupType,
        nets: []const NetIdx,
        tolerance: f32 = 0.05,
        preferred_layer: u8 = 0,
        route_priority: u8 = 128,
        thermal_tolerance: f32 = 0,
        coupling_tolerance: f32 = 0,
        shield_net: ?NetIdx = null,
        force_net: ?NetIdx = null,
        sense_net: ?NetIdx = null,
    };

    pub fn addGroup(self: *AnalogGroupDB, p: AddGroupParams) !void {
        // Validation
        if (p.nets.len == 0) return error.InvalidNetCount;
        if (p.tolerance < 0.0 or p.tolerance > 1.0) return error.InvalidTolerance;

        switch (p.group_type) {
            .differential => {
                if (p.nets.len != 2) return error.InvalidNetCount;
            },
            .kelvin => {
                if (p.force_net == null or p.sense_net == null) return error.MissingKelvinNets;
            },
            .shielded => {
                if (p.shield_net == null) return error.MissingShieldNet;
            },
            else => {},
        }

        if (self.len >= self.capacity) try self.grow();

        const i: usize = @intCast(self.len);

        self.group_type[i] = p.group_type;
        self.route_priority[i] = p.route_priority;
        self.tolerance[i] = p.tolerance;
        self.preferred_layer[i] = p.preferred_layer;
        self.status[i] = .pending;

        self.net_range_start[i] = @intCast(self.net_pool.items.len);
        self.net_count[i] = @intCast(p.nets.len);
        try self.net_pool.appendSlice(self.allocator, p.nets);

        self.name_offsets[i] = @intCast(self.name_bytes.items.len);
        try self.name_bytes.appendSlice(self.allocator, p.name);

        self.thermal_tolerance[i] = p.thermal_tolerance;
        self.coupling_tolerance[i] = p.coupling_tolerance;
        self.shield_net[i] = p.shield_net orelse NONE_NET;
        self.force_net[i] = p.force_net orelse NONE_NET;
        self.sense_net[i] = p.sense_net orelse NONE_NET;

        self.len += 1;
    }

    /// Get nets for a group.
    pub fn netsForGroup(self: *const AnalogGroupDB, idx: u32) []const NetIdx {
        const start = self.net_range_start[idx];
        const count = self.net_count[idx];
        return self.net_pool.items[start..][0..count];
    }

    /// Return group indices sorted by priority (ascending = highest priority first).
    pub fn sortedByPriority(self: *const AnalogGroupDB, allocator: std.mem.Allocator) ![]AnalogGroupIdx {
        const indices = try allocator.alloc(AnalogGroupIdx, self.len);
        for (0..self.len) |i| indices[i] = AnalogGroupIdx.fromInt(@intCast(i));

        const Context = struct {
            priorities: []const u8,
            pub fn lessThan(ctx: @This(), a: AnalogGroupIdx, b: AnalogGroupIdx) bool {
                return ctx.priorities[a.toInt()] < ctx.priorities[b.toInt()];
            }
        };
        std.mem.sort(AnalogGroupIdx, indices, Context{ .priorities = self.route_priority }, Context.lessThan);
        return indices;
    }

    fn grow(self: *AnalogGroupDB) !void {
        const new_cap = if (self.capacity == 0) @as(u32, 16) else self.capacity * 2;
        const n: usize = @intCast(new_cap);
        self.group_type = try self.allocator.realloc(self.group_type, n);
        self.route_priority = try self.allocator.realloc(self.route_priority, n);
        self.tolerance = try self.allocator.realloc(self.tolerance, n);
        self.preferred_layer = try self.allocator.realloc(self.preferred_layer, n);
        self.status = try self.allocator.realloc(self.status, n);
        self.net_range_start = try self.allocator.realloc(self.net_range_start, n);
        self.net_count = try self.allocator.realloc(self.net_count, n);
        self.name_offsets = try self.allocator.realloc(self.name_offsets, n);
        self.thermal_tolerance = try self.allocator.realloc(self.thermal_tolerance, n);
        self.coupling_tolerance = try self.allocator.realloc(self.coupling_tolerance, n);
        self.shield_net = try self.allocator.realloc(self.shield_net, n);
        self.force_net = try self.allocator.realloc(self.force_net, n);
        self.sense_net = try self.allocator.realloc(self.sense_net, n);
        self.capacity = new_cap;
    }
};
```

### 4.2 Exit Criteria

- Add differential group → validates exactly 2 nets, rejects 1 or 3
- Add kelvin group → rejects if force_net/sense_net missing
- Tolerance validation: rejects negative, rejects > 1.0
- Net lookup round-trip: addGroup with 3 nets → netsForGroup returns same 3 in order
- Priority sort: 3 groups with priorities [2,0,1] → sorted as [1,2,0] by index

---

## 5. Phase 4: Matched Router

### 5.1 New File: `src/router/symmetric_steiner.zig` (~300 lines)

Generates mirrored Steiner trees for matched net pairs.

**Algorithm:**
1. Compute symmetry axis from group pin centroid
2. Build Steiner tree for reference net (reuse `steiner.zig`)
3. Mirror each segment around axis to get paired net tree
4. Return both trees with matching topology

```zig
const std = @import("std");
const steiner_mod = @import("steiner.zig");
const at = @import("analog_types.zig");

const SteinerTree = steiner_mod.SteinerTree;
const SymmetryAxis = at.SymmetryAxis;

pub const SymmetricSteinerResult = struct {
    tree_ref: SteinerTree,    // reference net
    tree_mirror: SteinerTree, // mirrored net
    axis: SymmetryAxis,
    axis_value: f32,

    pub fn deinit(self: *SymmetricSteinerResult) void {
        self.tree_ref.deinit();
        self.tree_mirror.deinit();
    }
};

/// Build a symmetric pair of Steiner trees.
///
/// `pins_ref` and `pins_mirror` are pin positions for the two matched nets.
/// The axis is computed as the midpoint between the centroids of the two pin sets.
pub fn buildSymmetric(
    allocator: std.mem.Allocator,
    pins_ref: []const [2]f32,
    pins_mirror: []const [2]f32,
) !SymmetricSteinerResult {
    // Compute centroids
    var cx_ref: f32 = 0;
    var cy_ref: f32 = 0;
    for (pins_ref) |p| { cx_ref += p[0]; cy_ref += p[1]; }
    cx_ref /= @floatFromInt(pins_ref.len);
    cy_ref /= @floatFromInt(pins_ref.len);

    var cx_mir: f32 = 0;
    var cy_mir: f32 = 0;
    for (pins_mirror) |p| { cx_mir += p[0]; cy_mir += p[1]; }
    cx_mir /= @floatFromInt(pins_mirror.len);
    cy_mir /= @floatFromInt(pins_mirror.len);

    // Choose axis: if centroids differ more in X, use vertical axis (mirror X).
    // If they differ more in Y, use horizontal axis (mirror Y).
    const dx = @abs(cx_ref - cx_mir);
    const dy = @abs(cy_ref - cy_mir);
    const axis: SymmetryAxis = if (dx >= dy) .y else .x;
    const axis_value = switch (axis) {
        .y => (cx_ref + cx_mir) * 0.5,
        .x => (cy_ref + cy_mir) * 0.5,
    };

    // Build reference tree
    const tree_ref = try SteinerTree.build(allocator, pins_ref);

    // Mirror reference tree segments to create mirror tree
    var mirror_segs = std.ArrayList(SteinerTree.Segment).init(allocator);
    for (tree_ref.segments.items) |seg| {
        try mirror_segs.append(allocator, mirrorSegment(seg, axis, axis_value));
    }

    return .{
        .tree_ref = tree_ref,
        .tree_mirror = .{ .segments = mirror_segs, .allocator = allocator },
        .axis = axis,
        .axis_value = axis_value,
    };
}

fn mirrorSegment(seg: SteinerTree.Segment, axis: SymmetryAxis, val: f32) SteinerTree.Segment {
    return switch (axis) {
        .y => .{ // mirror across vertical axis (flip X)
            .x1 = 2.0 * val - seg.x1,
            .y1 = seg.y1,
            .x2 = 2.0 * val - seg.x2,
            .y2 = seg.y2,
        },
        .x => .{ // mirror across horizontal axis (flip Y)
            .x1 = seg.x1,
            .y1 = 2.0 * val - seg.y1,
            .x2 = seg.x2,
            .y2 = 2.0 * val - seg.y2,
        },
    };
}
```

### 5.2 New File: `src/router/matched_router.zig` (~600 lines)

The core matched routing engine. Routes matched net groups with parasitic symmetry.

**Algorithm per group:**
1. Determine routing strategy from `group_type`:
   - `differential` → symmetric Steiner + A* with matched cost
   - `matched` → route each net independently, then balance
   - `kelvin` → route force and sense separately (no shared segments)
   - `shielded` → route signal, then delegate to ShieldRouter (Phase 5)
2. For each Steiner edge: route via A* with `MatchedCostFn`
3. Balance wire lengths (add jogs to shorter net)
4. Balance via counts (add dummy vias where DRC-clean)

**Matched cost function** (injected into A* via wrapper, NOT by modifying astar.zig):

```zig
/// Route a single analog group.
/// This is the main entry point called per-group during the parallel routing phase.
pub fn routeAnalogGroup(
    db: *AnalogRouteDB,
    group_idx: AnalogGroupIdx,
    grid: *const MultiLayerGrid,
    scratch: std.mem.Allocator,
) !RoutingResult {
    const gi: usize = group_idx.toInt();
    const group_type = db.groups.group_type[gi];
    const nets = db.groups.netsForGroup(gi);
    const pref_layer = db.groups.preferred_layer[gi];
    const tolerance = db.groups.tolerance[gi];

    db.groups.status[gi] = .routing;

    const result = switch (group_type) {
        .differential => try routeDifferentialPair(db, group_idx, nets, grid, pref_layer, scratch),
        .matched => try routeMatchedGroup(db, group_idx, nets, grid, pref_layer, tolerance, scratch),
        .kelvin => try routeKelvinGroup(db, group_idx, nets, grid, scratch),
        .shielded => try routeShieldedGroup(db, group_idx, nets, grid, scratch),
        .resistor_matched, .capacitor_array => try routeMatchedGroup(db, group_idx, nets, grid, pref_layer, tolerance, scratch),
    };

    db.groups.status[gi] = if (result == .success) .routed else .failed;
    return result;
}
```

**Differential pair routing:**

```zig
fn routeDifferentialPair(
    db: *AnalogRouteDB,
    group_idx: AnalogGroupIdx,
    nets: []const NetIdx,  // exactly 2
    grid: *const MultiLayerGrid,
    pref_layer: u8,
    scratch: std.mem.Allocator,
) !RoutingResult {
    // 1. Get pin positions for both nets
    const pins_p = try getPinPositions(db, nets[0], scratch);
    const pins_n = try getPinPositions(db, nets[1], scratch);

    // 2. Build symmetric Steiner trees
    var sym = try symmetric_steiner.buildSymmetric(scratch, pins_p, pins_n);
    defer sym.deinit();

    // 3. Route reference net edges via A*
    var astar = AStarRouter.init(scratch);
    // If spatial DRC checker available, wire it in
    // astar.drc_checker = ...;

    for (sym.tree_ref.segments.items) |seg| {
        const src = grid.worldToNode(layerToGrid(pref_layer), seg.x1, seg.y1);
        const tgt = grid.worldToNode(layerToGrid(pref_layer), seg.x2, seg.y2);
        if (try astar.findPath(grid, src, tgt, nets[0])) |path| {
            defer path.deinit();
            try commitAnalogPath(db, group_idx, nets[0], grid, &path, pref_layer);
        } else {
            return .no_path;
        }
    }

    // 4. Route mirror net edges (same topology, mirrored coordinates)
    for (sym.tree_mirror.segments.items) |seg| {
        const src = grid.worldToNode(layerToGrid(pref_layer), seg.x1, seg.y1);
        const tgt = grid.worldToNode(layerToGrid(pref_layer), seg.x2, seg.y2);
        if (try astar.findPath(grid, src, tgt, nets[1])) |path| {
            defer path.deinit();
            try commitAnalogPath(db, group_idx, nets[1], grid, &path, pref_layer);
        } else {
            return .no_path;
        }
    }

    // 5. Balance wire lengths
    try balanceWireLengths(db, group_idx, nets, grid, scratch);

    // 6. Balance via counts
    try balanceViaCounts(db, group_idx, nets, grid, scratch);

    return .success;
}
```

**Wire-length balancing:**

```zig
fn balanceWireLengths(
    db: *AnalogRouteDB,
    group_idx: AnalogGroupIdx,
    nets: []const NetIdx,
    grid: *const MultiLayerGrid,
    scratch: std.mem.Allocator,
) !void {
    _ = grid; _ = scratch;

    // Find shortest and longest nets
    var min_len: f32 = std.math.inf(f32);
    var max_len: f32 = 0;
    var max_net: NetIdx = nets[0];

    for (nets) |net| {
        const len = db.segments.netLength(net);
        if (len < min_len) min_len = len;
        if (len > max_len) { max_len = len; max_net = net; }
    }

    const delta = max_len - min_len;
    if (delta < min_len * 0.005) return; // already within 0.5%

    // For each net shorter than max, add jog segments to match
    for (nets) |net| {
        if (net.toInt() == max_net.toInt()) continue;
        const len = db.segments.netLength(net);
        const needed = max_len - len;
        if (needed < 0.01) continue; // below resolution

        // Find a "silent" segment (long horizontal or vertical) on this net
        // and add a serpentine jog to extend length
        try addLengthJog(db, group_idx, net, needed);
    }
}

fn addLengthJog(
    db: *AnalogRouteDB,
    group_idx: AnalogGroupIdx,
    net: NetIdx,
    needed_length: f32,
) !void {
    // Find the longest segment for this net (best candidate for jog insertion)
    var best_idx: ?usize = null;
    var best_len: f32 = 0;
    const len: usize = @intCast(db.segments.len);

    for (0..len) |i| {
        if (db.segments.net[i].toInt() != net.toInt()) continue;
        if (db.segments.group[i].toInt() != group_idx.toInt()) continue;
        const seg_len = @abs(db.segments.x2[i] - db.segments.x1[i]) +
                        @abs(db.segments.y2[i] - db.segments.y1[i]);
        if (seg_len > best_len) {
            best_len = seg_len;
            best_idx = i;
        }
    }

    if (best_idx) |bi| {
        // Add serpentine: split segment at midpoint, insert U-shaped detour
        const mid_x = (db.segments.x1[bi] + db.segments.x2[bi]) * 0.5;
        const mid_y = (db.segments.y1[bi] + db.segments.y2[bi]) * 0.5;
        const jog_height = needed_length * 0.5; // U-shape adds 2x height
        const w = db.segments.width[bi];
        const l = db.segments.layer[bi];

        // Determine jog direction (perpendicular to segment)
        const is_horizontal = (db.segments.y1[bi] == db.segments.y2[bi]);
        if (is_horizontal) {
            // Add vertical detour at midpoint
            try db.segments.append(.{
                .x1 = mid_x, .y1 = mid_y,
                .x2 = mid_x, .y2 = mid_y + jog_height,
                .width = w, .layer = l, .net = net,
                .group = group_idx,
                .flags = .{ .is_jog = true },
            });
            try db.segments.append(.{
                .x1 = mid_x, .y1 = mid_y + jog_height,
                .x2 = mid_x, .y2 = mid_y,
                .width = w, .layer = l, .net = net,
                .group = group_idx,
                .flags = .{ .is_jog = true },
            });
        } else {
            // Add horizontal detour at midpoint
            try db.segments.append(.{
                .x1 = mid_x, .y1 = mid_y,
                .x2 = mid_x + jog_height, .y2 = mid_y,
                .width = w, .layer = l, .net = net,
                .group = group_idx,
                .flags = .{ .is_jog = true },
            });
            try db.segments.append(.{
                .x1 = mid_x + jog_height, .y1 = mid_y,
                .x2 = mid_x, .y2 = mid_y,
                .width = w, .layer = l, .net = net,
                .group = group_idx,
                .flags = .{ .is_jog = true },
            });
        }
    }
}
```

### 5.3 Modification to `src/router/astar.zig`

Do NOT modify `findPath` signature. Instead, the matched router creates a thread-local `AStarRouter` instance with custom `drc_checker` and cost parameters. The existing interface supports this:

```zig
var astar = AStarRouter.init(scratch_allocator);
astar.via_cost = 5.0;          // penalize via asymmetry
astar.congestion_weight = 1.0; // prefer uncongested paths
astar.wrong_way_cost = 5.0;    // strongly prefer preferred direction
// Wire in spatial DRC checker if available
```

### 5.4 Exit Criteria

- Differential pair: both nets routed, length mismatch < 1%, via delta <= 1
- Same-layer enforcement: all segments for matched group on same layer
- Single-pin nets: no crash, zero segments produced
- Coincident pins: no crash
- Via balancing: adds dummy vias marked with `is_dummy_via` flag

---

## 6. Phase 5: Shield Router

### 6.1 New File: `src/router/shield_router.zig` (~300 lines)

**Algorithm:**
1. For each segment of the shielded signal net, compute shield position on adjacent layer
2. Shield layer selection: if signal on M1 → shield on M2, if M2 → shield on M1 or M3
3. DRC check shield rect against spatial grid. Skip if conflict (shield continuity < DRC clean)
4. Connect shield segments to shield net (ground/VDD) with vias at ends
5. Mark shield segments with `is_shield = true`

```zig
pub const ShieldRouter = struct {
    db: *AnalogRouteDB,
    allocator: std.mem.Allocator,

    pub fn routeShielded(
        self: *ShieldRouter,
        group_idx: AnalogGroupIdx,
        signal_net: NetIdx,
        shield_net: NetIdx,
    ) !void {
        const segs = &self.db.segments;
        const len: usize = @intCast(segs.len);

        for (0..len) |i| {
            if (segs.net[i].toInt() != signal_net.toInt()) continue;
            if (segs.group[i].toInt() != group_idx.toInt()) continue;

            const sig_layer = segs.layer[i];
            // Shield on adjacent layer (prefer layer above)
            const shield_layer = if (sig_layer + 1 < self.db.pdk.num_metal_layers + 1)
                sig_layer + 1
            else if (sig_layer > 1)
                sig_layer - 1
            else
                continue; // can't shield LI

            // Compute shield rect (same x/y extent, parallel on adjacent layer)
            const shield_width = self.db.pdk.min_width[pdkIdx(shield_layer)];

            // Check DRC before placing
            // (use SpatialDrcChecker if available, otherwise skip DRC check)
            const drc_ok = true; // TODO: wire in SpatialDrcChecker

            if (drc_ok) {
                try segs.append(.{
                    .x1 = segs.x1[i], .y1 = segs.y1[i],
                    .x2 = segs.x2[i], .y2 = segs.y2[i],
                    .width = shield_width,
                    .layer = shield_layer,
                    .net = shield_net,
                    .group = group_idx,
                    .flags = .{ .is_shield = true },
                });
            }
        }
    }

    fn pdkIdx(route_layer: u8) usize {
        return @as(usize, route_layer) -| 1;
    }
};
```

### 6.2 Exit Criteria

- Shield wires generated on adjacent layer
- DRC conflict → segment skipped (not crash)
- Driven guard: shield_net = signal potential, not ground
- All shield segments marked `is_shield = true`

---

## 7. Phase 6: Guard Ring Inserter

### 7.1 New File: `src/router/guard_ring.zig` (~400 lines)

**Algorithm:**
1. Compute ring bbox = analog block bbox + `pdk.guard_ring_spacing` on each side
2. Generate 4 edges of donut (outer rect - inner rect) on appropriate layer (LI or M1)
3. Place contacts at `pdk.guard_ring_width` pitch along ring
4. Register ring segments with spatial grid and DRC checker
5. Handle edge cases: die edge clipping, existing metal stitch-in, adjacent block merging

**Key PDK values** (from `layout_if.zig`):
- `guard_ring_width` = 0.34 µm (SKY130 default)
- `guard_ring_spacing` = 0.34 µm

```zig
pub const GuardRingInserter = struct {
    db: *AnalogRouteDB,

    pub const InsertParams = struct {
        region: Rect,        // analog block bbox
        ring_type: GuardRingType,
        net: NetIdx,         // VSS or VDD
    };

    pub fn insert(self: *GuardRingInserter, params: InsertParams) !GuardRingResult {
        const spacing = self.db.pdk.guard_ring_spacing;
        const width = self.db.pdk.guard_ring_width;

        // Outer bbox = region expanded by spacing + width/2
        var outer = params.region.expand(spacing + width * 0.5);

        // Clip to die bbox
        outer.x1 = @max(outer.x1, self.db.die_bbox.x1);
        outer.y1 = @max(outer.y1, self.db.die_bbox.y1);
        outer.x2 = @min(outer.x2, self.db.die_bbox.x2);
        outer.y2 = @min(outer.y2, self.db.die_bbox.y2);

        // Generate 4 ring edges as route segments on route layer 1 (M1)
        const layer: u8 = 1; // M1
        const net = params.net;
        const gid = AnalogGroupIdx.fromInt(0); // guard rings don't belong to analog groups

        // Bottom edge
        try self.db.segments.append(.{
            .x1 = outer.x1, .y1 = outer.y1,
            .x2 = outer.x2, .y2 = outer.y1,
            .width = width, .layer = layer, .net = net, .group = gid,
        });
        // Top edge
        try self.db.segments.append(.{
            .x1 = outer.x1, .y1 = outer.y2,
            .x2 = outer.x2, .y2 = outer.y2,
            .width = width, .layer = layer, .net = net, .group = gid,
        });
        // Left edge
        try self.db.segments.append(.{
            .x1 = outer.x1, .y1 = outer.y1,
            .x2 = outer.x1, .y2 = outer.y2,
            .width = width, .layer = layer, .net = net, .group = gid,
        });
        // Right edge
        try self.db.segments.append(.{
            .x1 = outer.x2, .y1 = outer.y1,
            .x2 = outer.x2, .y2 = outer.y2,
            .width = width, .layer = layer, .net = net, .group = gid,
        });

        return .{
            .bbox = outer,
            .clipped = (outer.x1 == self.db.die_bbox.x1 or
                       outer.y1 == self.db.die_bbox.y1 or
                       outer.x2 == self.db.die_bbox.x2 or
                       outer.y2 == self.db.die_bbox.y2),
        };
    }

    pub const GuardRingResult = struct {
        bbox: Rect,
        clipped: bool,
    };
};
```

### 7.2 Exit Criteria

- Ring fully encloses region with margin
- Die edge clipping: ring coords clamped to die bbox
- Contact generation at configurable pitch
- DRC clean

---

## 8. Phase 7: Thermal Router

### 8.1 New File: `src/router/thermal.zig` (~300 lines)

Dense 2D grid of temperatures. O(1) query.

```zig
pub const ThermalMap = struct {
    temps: []f32,     // row-major: cell(x,y) = temps[y * cols + x]
    cols: u32,
    rows: u32,
    cell_size: f32,   // µm — typically 10.0
    origin_x: f32,
    origin_y: f32,
    ambient: f32,     // ambient temperature in °C

    pub fn init(allocator: std.mem.Allocator, die_bbox: Rect, cell_size: f32, ambient: f32) !ThermalMap {
        const w = die_bbox.x2 - die_bbox.x1;
        const h = die_bbox.y2 - die_bbox.y1;
        const cols: u32 = @intFromFloat(@ceil(w / cell_size)) + 1;
        const rows: u32 = @intFromFloat(@ceil(h / cell_size)) + 1;
        const total: usize = @intCast(@as(u64, cols) * @as(u64, rows));

        const temps = try allocator.alloc(f32, total);
        @memset(temps, ambient);

        return .{
            .temps = temps,
            .cols = cols, .rows = rows,
            .cell_size = cell_size,
            .origin_x = die_bbox.x1,
            .origin_y = die_bbox.y1,
            .ambient = ambient,
        };
    }

    pub fn deinit(self: *ThermalMap, allocator: std.mem.Allocator) void {
        allocator.free(self.temps);
    }

    /// O(1) temperature query.
    pub inline fn query(self: *const ThermalMap, x: f32, y: f32) f32 {
        const cx: u32 = @min(
            @as(u32, @intFromFloat(@max(0, (x - self.origin_x) / self.cell_size))),
            self.cols - 1,
        );
        const cy: u32 = @min(
            @as(u32, @intFromFloat(@max(0, (y - self.origin_y) / self.cell_size))),
            self.rows - 1,
        );
        return self.temps[cy * self.cols + cx];
    }

    /// Add a hotspot with Gaussian-like diffusion.
    pub fn addHotspot(self: *ThermalMap, hx: f32, hy: f32, delta_t: f32, radius: f32) void {
        const r_cells = @as(u32, @intFromFloat(@ceil(radius / self.cell_size)));
        const center_col: i64 = @intFromFloat((hx - self.origin_x) / self.cell_size);
        const center_row: i64 = @intFromFloat((hy - self.origin_y) / self.cell_size);

        const r_sq = radius * radius;

        var dy: i64 = -@as(i64, r_cells);
        while (dy <= @as(i64, r_cells)) : (dy += 1) {
            var dx: i64 = -@as(i64, r_cells);
            while (dx <= @as(i64, r_cells)) : (dx += 1) {
                const col = center_col + dx;
                const row = center_row + dy;
                if (col < 0 or col >= self.cols or row < 0 or row >= self.rows) continue;

                const dist_sq = @as(f32, @floatFromInt(dx * dx + dy * dy)) * self.cell_size * self.cell_size;
                if (dist_sq > r_sq) continue;

                const decay = 1.0 - dist_sq / r_sq; // linear decay
                const idx: usize = @intCast(@as(u64, @intCast(row)) * self.cols + @as(u64, @intCast(col)));
                self.temps[idx] += delta_t * decay;
            }
        }
    }

    /// Compute thermal gradient cost between two points.
    /// Used as additional cost term in A* for matched routing.
    pub fn gradientCost(self: *const ThermalMap, x1: f32, y1: f32, x2: f32, y2: f32) f32 {
        return @abs(self.query(x1, y1) - self.query(x2, y2));
    }
};
```

### 8.2 Exit Criteria

- Hotspot query returns > ambient at center, ~ambient far away
- Gradient cost = 0 for two equidistant points (same isotherm)
- 10mm die / 10µm cell = 1M cells = 4MB (fits L3)

---

## 9. Phase 8: LDE Router

### 9.1 New File: `src/router/lde.zig` (~250 lines)

LOD/WPE-aware keepout zones and cost function.

```zig
pub const LDEConstraintDB = struct {
    device: []DeviceIdx,
    min_sa: []f32,    // min gate-to-STI source side (µm)
    min_sb: []f32,    // min gate-to-STI drain side (µm)
    max_sa: []f32,
    max_sb: []f32,
    sc_target: []f32, // well proximity target (µm)
    len: u32,
    capacity: u32,
    allocator: std.mem.Allocator,

    // init, deinit, addConstraint, grow — same pattern as other SoA tables

    /// Generate keepout rects: device bbox expanded by SA/SB on each side.
    /// Routes must not enter these zones to preserve LDE symmetry.
    pub fn generateKeepouts(
        self: *const LDEConstraintDB,
        device_positions: []const [2]f32,
        device_dimensions: []const [2]f32,
        allocator: std.mem.Allocator,
    ) ![]Rect {
        var keepouts = try allocator.alloc(Rect, self.len);
        for (0..self.len) |i| {
            const di = self.device[i].toInt();
            const px = device_positions[di][0];
            const py = device_positions[di][1];
            const hw = device_dimensions[di][0] * 0.5;
            const hh = device_dimensions[di][1] * 0.5;
            keepouts[i] = .{
                .x1 = px - hw - self.min_sa[i],
                .y1 = py - hh - self.min_sb[i],
                .x2 = px + hw + self.min_sa[i],
                .y2 = py + hh + self.min_sb[i],
            };
        }
        return keepouts;
    }
};

/// Cost function for LDE-aware routing.
/// Penalizes SA/SB asymmetry between matched devices.
pub fn computeLDECost(
    sa_a: f32, sb_a: f32,  // device A measurements
    sa_b: f32, sb_b: f32,  // device B measurements
) f32 {
    const delta_sa = @abs(sa_a - sa_b);
    const delta_sb = @abs(sb_a - sb_b);
    return delta_sa + delta_sb;
}
```

---

## 10. Phase 9: PEX Feedback Loop

### 10.1 New File: `src/router/pex_feedback.zig` (~300 lines)

**Algorithm:**
```
for iteration in 0..max_iterations(5):
    route all analog groups (Phase 4-8)
    extract PEX per-net (call into existing characterize/pex.zig)
    compute MatchReport per group
    split groups into passing/failing (existence-based)
    if all pass → break
    for each failing group:
        determine dominant mismatch → select RepairAction
        rip up group segments
        apply repair adjustments (width, layer, jog, dummy via)
    re-route failing groups
return final status
```

```zig
pub const MatchReportDB = struct {
    group: []AnalogGroupIdx,
    pass: []bool,
    r_ratio: []f32,       // max(R)/min(R) - 1.0
    c_ratio: []f32,       // max(C)/min(C) - 1.0
    length_ratio: []f32,  // max(len)/min(len) - 1.0
    via_delta: []i16,     // |max_vias - min_vias|
    coupling_delta: []f32,
    thermal_gradient: []f32,  // 0 = no constraint
    recommended_action: []RepairAction,
    len: u32,
    capacity: u32,
    allocator: std.mem.Allocator,

    // init, deinit, append — same SoA pattern
};

pub fn routeWithPexFeedback(
    db: *AnalogRouteDB,
    grid: *const MultiLayerGrid,
    max_iterations: u8,
) !RoutingResult {
    var all_pass = false;

    for (0..max_iterations) |iteration| {
        _ = iteration;

        // 1. Route all pending/failed groups
        const order = try db.groups.sortedByPriority(db.pass_arena.allocator());
        for (order) |gid| {
            const gi = gid.toInt();
            if (db.groups.status[gi] == .routed) continue;
            _ = try routeAnalogGroup(db, gid, grid, db.pass_arena.allocator());
        }

        // 2. Extract PEX per-net (calls into characterize/pex.zig)
        // try extractParasitics(db);

        // 3. Compute match reports
        try computeMatchReports(db);

        // 4. Check convergence
        all_pass = true;
        for (0..db.match_reports.len) |i| {
            if (!db.match_reports.pass[i]) {
                all_pass = false;
                break;
            }
        }
        if (all_pass) break;

        // 5. Repair failing groups
        for (0..db.match_reports.len) |i| {
            if (db.match_reports.pass[i]) continue;
            const gid = db.match_reports.group[i];
            const action = db.match_reports.recommended_action[i];

            // Rip up
            db.segments.removeGroup(gid);
            db.groups.status[gid.toInt()] = .pending;

            // Apply repair adjustment
            switch (action) {
                .adjust_width => {}, // modify preferred width for next route
                .adjust_layer => {}, // change preferred_layer
                .add_jog => {},      // lower tolerance for jog insertion
                .add_dummy_via => {},
                .rebalance_layer => {},
                .none => {},
            }
        }

        // 6. Rebuild spatial grid for next iteration
        try db.spatial.rebuild(
            db.segments.x1, db.segments.y1,
            db.segments.x2, db.segments.y2,
            db.segments.len,
        );

        db.resetPass();
    }

    return if (all_pass) .success else .mismatch_exceeded;
}

fn computeMatchReports(db: *AnalogRouteDB) !void {
    db.match_reports.len = 0;

    for (0..db.groups.len) |gi| {
        const nets = db.groups.netsForGroup(@intCast(gi));
        if (nets.len < 2) continue;

        // Compute per-net metrics
        var min_len: f32 = std.math.inf(f32);
        var max_len: f32 = 0;
        var min_vias: u32 = std.math.maxInt(u32);
        var max_vias: u32 = 0;

        for (nets) |net| {
            const len = db.segments.netLength(net);
            const vias = db.segments.viaCount(net);
            min_len = @min(min_len, len);
            max_len = @max(max_len, len);
            min_vias = @min(min_vias, vias);
            max_vias = @max(max_vias, vias);
        }

        const length_ratio = if (min_len > 0) (max_len / min_len) - 1.0 else 0;
        const via_delta: i16 = @intCast(@as(i32, @intCast(max_vias)) - @as(i32, @intCast(min_vias)));
        const tolerance = db.groups.tolerance[gi];

        const pass = (length_ratio <= tolerance) and (@abs(via_delta) <= 1);

        // Determine repair action
        const action: RepairAction = if (pass) .none else blk: {
            if (length_ratio > tolerance) break :blk .add_jog;
            if (@abs(via_delta) > 1) break :blk .add_dummy_via;
            break :blk .none;
        };

        try db.match_reports.append(.{
            .group = AnalogGroupIdx.fromInt(@intCast(gi)),
            .pass = pass,
            .r_ratio = 0, // populated after PEX extraction
            .c_ratio = 0,
            .length_ratio = length_ratio,
            .via_delta = via_delta,
            .coupling_delta = 0,
            .thermal_gradient = 0,
            .recommended_action = action,
        });
    }
}
```

### 10.2 Exit Criteria

- 5 iteration cap
- Reports generated for all matched groups
- Failing groups correctly identified and repaired
- Converges on simple diff pair within 2 iterations

---

## 11. Phase 10: Thread Pool + Parallel Dispatch

### 11.1 New File: `src/router/parallel_router.zig` (~500 lines)

Implements the 5-phase parallel routing pipeline from GUIDE_03.

**Key structures:**
- `GroupDependencyGraph` — adjacency list, O(n²) pair check
- `colorGroups` — greedy graph coloring
- `ThreadPool` — SPMC work queue, spawn/join per wavefront
- `routeAllGroups` — orchestrator

**Threading invariants** (from GUIDE_03):
- Grid: read-only during parallel phase. Rebuilt O(n) between wavefronts.
- Segments: thread-local buffers. Merged sequentially after wavefront barrier.
- A* state: thread-local instances, no sharing.
- Group status: atomic write (relaxed ordering).
- Zero locks in entire system.

**Sequential fallback:** `num_threads <= 1 OR num_groups < 4` → skip thread pool entirely.

**Thread count:** `min(num_groups, cpu_count, 16)`.

```zig
pub fn routeAllGroups(db: *AnalogRouteDB, grid: *const MultiLayerGrid) !void {
    const num_groups = db.groups.len;
    if (num_groups == 0) return;

    const num_threads = selectThreadCount(num_groups);

    if (num_threads <= 1 or num_groups < 4) {
        // Sequential
        const order = try db.groups.sortedByPriority(db.pass_arena.allocator());
        for (order) |gid| {
            _ = try routeAnalogGroup(db, gid, grid, db.pass_arena.allocator());
        }
        return;
    }

    // Build dependency graph
    // ... (see GUIDE_03 for full code)

    // Color groups → wavefronts
    // ... greedy coloring

    // Route wavefronts
    // for each wavefront:
    //   spawn threads, each claims groups from work queue
    //   barrier: join all threads
    //   merge thread-local segments → global
    //   rebuild spatial grid O(n)
}

fn selectThreadCount(num_groups: u32) u8 {
    const hw = std.Thread.getCpuCount() catch 4;
    return @intCast(@min(@min(num_groups, hw), 16));
}
```

### 11.2 Exit Criteria

- All work items executed (atomic counter matches total)
- Sequential and parallel produce identical results (deterministic)
- No data races (verify with ThreadSanitizer if available)
- Wavefront coloring: no two adjacent groups share a color
- Independent groups: same color (can run in parallel)

---

## 12. Phase 11: Integration + Signoff

### 12.1 Modifications to `src/router/detailed.zig`

Add analog routing path BEFORE digital routing in `routeAll`:

```zig
pub fn routeAll(self: *DetailedRouter, ...) !void {
    // Build grid (existing code)
    self.grid = try MultiLayerGrid.init(...);

    // ── NEW: Route analog nets first ──
    if (analog_constraints != null) {
        var analog_db = try AnalogRouteDB.init(self.allocator, pdk, die_bbox, 4);
        defer analog_db.deinit();

        // Populate groups from constraints
        // ...

        // Route with PEX feedback
        try routeWithPexFeedback(&analog_db, &self.grid.?, 5);

        // Merge analog segments into main RouteArrays
        try analog_db.segments.toRouteArrays(&self.routes);

        // Mark analog segments in grid (claim cells)
        // ...
    }

    // ── Existing: Route digital nets ──
    // (existing code continues, now aware of analog-claimed cells)
}
```

### 12.2 Modifications to `src/router/lib.zig`

Add all new module exports:

```zig
pub const analog_types = @import("analog_types.zig");
pub const analog_db = @import("analog_db.zig");
pub const analog_groups = @import("analog_groups.zig");
pub const spatial_grid = @import("spatial_grid.zig");
pub const matched_router = @import("matched_router.zig");
pub const symmetric_steiner = @import("symmetric_steiner.zig");
pub const shield_router = @import("shield_router.zig");
pub const guard_ring = @import("guard_ring.zig");
pub const thermal = @import("thermal.zig");
pub const lde = @import("lde.zig");
pub const pex_feedback = @import("pex_feedback.zig");
pub const parallel_router = @import("parallel_router.zig");

pub const AnalogRouteDB = analog_db.AnalogRouteDB;
pub const AnalogRouter = parallel_router; // primary API
```

### 12.3 Test Circuits

1. **Simple diff pair** — 2 nets, 4 pins, M2 preferred. Expect: zero DRC, < 1% length mismatch.
2. **Current mirror** — 4 matched nets, 8 pins. Expect: R/C within 5%.
3. **Kelvin connection** — force + sense nets. Expect: no shared segments.
4. **Shielded net** — signal + ground shield. Expect: shield on adjacent layer, DRC clean.
5. **Guard ring** — P+ ring around analog block. Expect: complete enclosure.

### 12.4 Exit Criteria

- All 5 test circuits pass
- Zero DRC violations on routed output
- LVS clean (segments match expected netlist)
- PEX matching within tolerance for all groups

---

## 13. File Map

### New Files (13)

| File | Phase | Lines (est.) |
|------|-------|-------------|
| `src/router/analog_types.zig` | 1 | 200 |
| `src/router/analog_db.zig` | 1 | 400 |
| `src/router/spatial_grid.zig` | 2 | 500 |
| `src/router/analog_groups.zig` | 3 | 350 |
| `src/router/matched_router.zig` | 4 | 600 |
| `src/router/symmetric_steiner.zig` | 4 | 300 |
| `src/router/shield_router.zig` | 5 | 300 |
| `src/router/guard_ring.zig` | 6 | 400 |
| `src/router/thermal.zig` | 7 | 300 |
| `src/router/lde.zig` | 8 | 250 |
| `src/router/pex_feedback.zig` | 9 | 300 |
| `src/router/parallel_router.zig` | 10 | 500 |
| `src/router/analog_tests.zig` | 1-11 | 2000 |

**Total new: ~6,400 lines** (excluding tests: ~4,400)

### Modified Files (4)

| File | Phases | Change |
|------|--------|--------|
| `src/router/lib.zig` | 1, 11 | Export new modules, add test references |
| `src/router/detailed.zig` | 11 | Add analog routing path before digital |
| `src/router/inline_drc.zig` | 2 | No modification — SpatialDrcChecker is a separate struct in spatial_grid.zig |
| `src/characterize/pex.zig` | 9 | Add `extractNet()` for per-net parasitic extraction |

**Decision: Do NOT modify `astar.zig` or `steiner.zig`.** The existing interfaces are sufficient. The matched router wraps them with its own cost adjustments by configuring the AStarRouter instance parameters.

---

## 14. Dependency Graph

```
core/types.zig (existing)
    │
    ▼
analog_types.zig ──┬──────────────────────────────────────────┐
    │              │                                          │
    ▼              ▼                                          │
analog_db.zig   spatial_grid.zig                              │
    │              │                                          │
    ├──────────────┤                                          │
    │              │                                          │
    ▼              ▼                                          │
analog_groups.zig                                             │
    │                                                         │
    ├───────┬───────┬──────────┬──────────┐                   │
    ▼       ▼       ▼          ▼          ▼                   │
matched_ shield_ guard_     thermal.   lde.zig               │
router   router  ring.zig   zig                               │
    │       │       │          │          │                   │
    ├───────┴───────┴──────────┴──────────┘                   │
    ▼                                                         │
pex_feedback.zig                                              │
    │                                                         │
    ▼                                                         │
parallel_router.zig                                           │
    │                                                         │
    ▼                                                         │
lib.zig ◄── detailed.zig                                      │
```

Build order = phase order. Each phase depends only on earlier phases.

---

## 15. Decision Log

Autonomous decisions made where guides were ambiguous:

| # | Decision | Rationale |
|---|----------|-----------|
| 1 | Analog ID types in `analog_types.zig`, NOT in `core/types.zig` | Avoid coupling core to analog router. Core is imported by many subsystems. |
| 2 | `SegmentFlags` as `packed struct(u8)` instead of 3 separate `[]bool` | One byte per segment instead of 3. Same cache line usage. Cleaner API. |
| 3 | Do NOT modify `astar.zig` interface | Existing `AStarRouter` parameters (via_cost, congestion_weight, wrong_way_cost, drc_checker) are sufficient for matched routing cost tuning. Avoids breaking existing tests. |
| 4 | Do NOT modify `steiner.zig` | The `SteinerTree.build()` interface is sufficient. Symmetric Steiner is a wrapper that builds two trees via the existing API + mirroring. |
| 5 | `SpatialDrcChecker` in `spatial_grid.zig`, NOT replacing `InlineDrcChecker` | Parallel type. Old code keeps working. Migration is opt-in per caller. |
| 6 | Route layer convention: use u8 everywhere (not LayerIdx) | Existing router code uses `u8` for layers (RouteArrays, InlineDrcChecker, MultiLayerGrid). Consistency > type safety here. LayerIdx is u16, wasteful for 5-layer stacks. |
| 7 | Guard rings on M1 (route_layer=1) | SKY130 guard rings use diffusion + contacts, but for routing purposes the keepout is at M1 level. |
| 8 | Thermal map cell_size = 10.0 µm (coarse) | Thermal gradients are mm-scale. 10µm resolution captures the physics without exploding memory. |
| 9 | Max 16 threads | Analog routing is memory-bandwidth-bound. More than 16 threads fight over L3. GUIDE_03 agrees. |
| 10 | PEX feedback: geometry-based metrics first (length, via count), R/C extraction deferred | Wire in R/C extraction from `characterize/pex.zig` when that module has `extractNet()`. Until then, length/via matching provides 80% of the value. |
| 11 | `AnalogGroupDB.NONE_NET = NetIdx.fromInt(0xFFFFFFFF)` sentinel | Avoids `?NetIdx` (optional adds 4 bytes for the tag on non-packed types). Sentinel value is never a valid net index in practice. |
| 12 | Jog insertion: single U-shaped detour on longest segment | Simplest approach that works. More sophisticated serpentine insertion is a Phase 4 refinement after basic matching is proven. |
| 13 | `toRouteArrays` uses `@memcpy` not element-wise copy | SoA columns are contiguous. `@memcpy` is the fastest transfer. Works because geometry columns in AnalogSegmentDB match RouteArrays column types exactly. |
| 14 | `RouteArrays.growTo` is public (called from `toRouteArrays`) | The existing `growTo` is private (`fn`). Either make it `pub fn` or add a public `ensureCapacity`. Prefer making it `pub` — it's a simple realloc, no risk. |

---

## Memory Budget

| Table | Rows | Hot bytes/row | Hot total | Cold bytes/row | Cold total |
|-------|------|--------------|-----------|---------------|------------|
| Groups | 200 | 10 | 2 KB | 28 | 5.6 KB |
| Segments | 50K | 26 | 1.3 MB | 12 | 600 KB |
| Spatial grid | 500K cells | 6 | 3 MB | — | — |
| Thermal map | 1M cells | 4 | 4 MB | — | — |
| Match reports | 200 | 20 | 4 KB | — | — |
| **Total** | — | — | **~8.3 MB** | — | **~606 KB** |

Hot working set fits in L3 (typical 6-30 MB). Cold data stays in DRAM.

---

## Risk Register

| Risk | Impact | Mitigation |
|------|--------|------------|
| PEX feedback doesn't converge | Can't guarantee R/C matching | Cap at 5 iterations, report best-effort with metrics |
| Thread contention on spatial grid | No speedup | Read-only during routing, rebuild between wavefronts |
| Guard ring DRC interactions | False violations | Stitch-in strategy; post-route signoff DRC |
| Thermal map accuracy | Suboptimal routing | User-supplied hotspots override diffusion model |
| Memory pressure | OOM on large designs | Arena allocation, pre-computed capacity, comptime @sizeOf budgets |
| `RouteArrays.growTo` is private | Can't call from `toRouteArrays` | Make `growTo` `pub fn` (single-line change in route_arrays.zig) |
| `SteinerTree` 256-point buffer overflow | Panic on large nets | Check pin count before calling. If > 256, fall back to pairwise MST. |
