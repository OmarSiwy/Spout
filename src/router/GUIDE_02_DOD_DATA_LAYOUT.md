# Data-Oriented Data Layout Guide

Every struct in the analog router is designed for cache efficiency. This document specifies exact memory layouts, SoA decompositions, hot/cold splits, existence tables, and cache line budgets.

---

## Principles Applied

1. **Tables, not objects.** Analog net groups, segments, shield wires, guard rings = rows in flat tables.
2. **IDs, not pointers.** All cross-table references use opaque `enum(u32) { _ }` types from `types.zig`.
3. **SoA via MultiArrayList** for tables with >100 rows where hot loops read <50% of fields.
4. **Hot/cold split** when access frequency differs sharply (e.g., routing cost fields vs debug info).
5. **Existence tables** replace booleans. "Is this net shielded?" = membership in `shielded_nets` table.
6. **Arena allocation** for data with shared lifetime (per-route-pass, per-group).

---

## New ID Types

Add to `src/core/types.zig`:

```zig
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
```

**Rationale:** `GuardRingIdx` is `u16` — a design with >65K guard rings is unreasonable. `SegmentIdx` is `u32` — large designs can have millions of route segments. Each type is distinct at compile time; mixing `SegmentIdx` with `NetIdx` is a compile error.

---

## Table 1: AnalogGroupDB (SoA)

Stores all analog net group metadata. Iterated during group routing dispatch.

```zig
// src/router/analog_groups.zig

pub const AnalogGroupType = enum(u8) {
    differential,     // 2 nets, mirrored routing
    matched,          // N nets, same R/C/length/vias
    shielded,         // 1 net + shield net
    kelvin,           // force + sense nets
    resistor_matched, // resistor segments in CC
    capacitor_array,  // unit cap array
};

/// SoA table for analog net groups. Hot fields packed together.
pub const AnalogGroupDB = struct {
    // ── Hot fields (touched every routing iteration) ──
    group_type: []AnalogGroupType,       // 1B  — dispatch key
    route_priority: []u8,                // 1B  — sort key for routing order
    tolerance: []f32,                    // 4B  — matching tolerance
    preferred_layer: []?LayerIdx,        // 3B  — target metal layer (null = any)
    status: []GroupStatus,               // 1B  — pending/routed/failed

    // ── Net membership (variable-length, flattened) ──
    // For group i: nets are net_pool[net_range_start[i]..net_range_start[i]+net_count[i]]
    net_range_start: []u32,              // 4B  — offset into net_pool
    net_count: []u8,                     // 1B  — number of nets in group (max 255)
    net_pool: []NetIdx,                  // Flat pool of all net IDs

    // ── Cold fields (touched only during setup or reporting) ──
    name_offsets: []u32,                 // offset into name_bytes
    name_bytes: []u8,                    // interned group names
    thermal_tolerance: []?f32,           // null = no thermal constraint
    coupling_tolerance: []?f32,          // null = use default
    shield_net: []?NetIdx,              // null = not shielded
    force_net: []?NetIdx,               // null = not kelvin
    sense_net: []?NetIdx,               // null = not kelvin
    centroid_pattern: []?CentroidPatternIdx, // index into patterns table

    // ── Bookkeeping ──
    len: u32,
    capacity: u32,
    allocator: std.mem.Allocator,

    pub const GroupStatus = enum(u8) {
        pending,
        routing,
        routed,
        failed,
    };
};
```

### Cache Analysis

**Hot loop (dispatch):** reads `group_type` + `route_priority` + `status` = 3 bytes/group.
At 200 groups: 600 bytes. Fits in 10 cache lines.

**Routing loop:** reads `group_type` + `tolerance` + `preferred_layer` + `net_range_start` + `net_count` = 13 bytes/group.
At 200 groups: 2,600 bytes. Fits in 41 cache lines. L1 resident.

**Cold fields never enter cache during routing.** Name strings, thermal tolerances, coupling tolerances stay in L3/DRAM.

---

## Table 2: AnalogSegmentDB (SoA)

Route segments produced by the analog router. Compatible with existing `RouteArrays` but adds analog-specific fields.

```zig
// src/router/analog_db.zig

/// SoA segment storage for analog-routed wires.
/// Layout matches RouteArrays columns for direct copy to output.
pub const AnalogSegmentDB = struct {
    // ── Geometry (hot — touched by DRC, PEX, rendering) ──
    x1: []f32,           // 4B
    y1: []f32,           // 4B
    x2: []f32,           // 4B
    y2: []f32,           // 4B
    width: []f32,        // 4B
    layer: []u8,         // 1B
    net: []NetIdx,       // 4B

    // ── Analog metadata (warm — touched by matching analysis) ──
    group: []AnalogGroupIdx,  // 4B — which analog group owns this
    is_shield: []bool,        // 1B — shield wire (not signal)
    is_dummy_via: []bool,     // 1B — dummy via for count balancing
    is_jog: []bool,           // 1B — matching jog (not shortest path)

    // ── PEX cache (cold — populated after extraction, read by repair) ──
    resistance: []f32,        // 4B — extracted R per segment
    capacitance: []f32,       // 4B — extracted C per segment
    coupling_cap: []f32,      // 4B — coupling to neighbors

    // ── Bookkeeping ──
    len: u32,
    capacity: u32,
    allocator: std.mem.Allocator,

    /// Copy geometry columns to RouteArrays for output.
    pub fn toRouteArrays(self: *const AnalogSegmentDB, out: *RouteArrays) !void {
        const n = self.len;
        try out.growTo(out.len + n);
        const base: usize = @intCast(out.len);
        @memcpy(out.layer[base..][0..n], self.layer[0..n]);
        @memcpy(out.x1[base..][0..n], self.x1[0..n]);
        @memcpy(out.y1[base..][0..n], self.y1[0..n]);
        @memcpy(out.x2[base..][0..n], self.x2[0..n]);
        @memcpy(out.y2[base..][0..n], self.y2[0..n]);
        @memcpy(out.width[base..][0..n], self.width[0..n]);
        @memcpy(out.net[base..][0..n], self.net[0..n]);
        out.len += n;
    }
};
```

### Cache Analysis

**DRC check per segment:** reads x1, y1, x2, y2, layer, net = 21 bytes.
At 10K segments, geometry columns = 210 KB. Fits in L2. Shield/jog/dummy bools never loaded.

**PEX extraction:** reads geometry + resistance + capacitance = 33 bytes/segment.
At 10K segments: 330 KB. L2/L3 boundary. Acceptable — PEX runs once per iteration.

---

## Table 3: SpatialGrid (Uniform Grid for DRC/Coupling)

```zig
// src/router/spatial_grid.zig

pub const SpatialGrid = struct {
    /// Per-cell list of segment indices. Flat pool with offset/count indexing.
    cell_offsets: []u32,      // cells_x * cells_y entries
    cell_counts: []u16,       // max 65K segments per cell (generous)
    segment_pool: []SegmentIdx, // flat array, cells index into this

    // Grid parameters
    cells_x: u32,
    cells_y: u32,
    cell_size: f32,           // in um — typically 2 * max(min_spacing)
    origin_x: f32,
    origin_y: f32,

    allocator: std.mem.Allocator,

    /// O(1) cell lookup from world coordinates.
    pub inline fn cellIndex(self: *const SpatialGrid, x: f32, y: f32) u32 {
        const cx: u32 = @intFromFloat(@max(0.0, (x - self.origin_x) / self.cell_size));
        const cy: u32 = @intFromFloat(@max(0.0, (y - self.origin_y) / self.cell_size));
        const clamped_x = @min(cx, self.cells_x - 1);
        const clamped_y = @min(cy, self.cells_y - 1);
        return clamped_y * self.cells_x + clamped_x;
    }

    /// Query 3x3 neighborhood. Returns slice of segment indices.
    /// Caller iterates returned indices, checks actual geometry.
    pub fn queryNeighborhood(
        self: *const SpatialGrid,
        x: f32,
        y: f32,
    ) NeighborIterator {
        // Returns iterator over 9 cells centered on (x,y)
        // Each cell yields its segment_pool[offset..offset+count] slice
    }
};
```

### Cache Analysis

**Per-query:** 9 cells x (4B offset + 2B count) = 54 bytes metadata. 1 cache line.
Plus segment indices: 9 cells x ~10 segments/cell x 4B = 360 bytes. 6 cache lines.
**Total per query: ~7 cache lines.** Compare to linear scan of 10K segments = 40KB = 625 lines.

### Why Uniform Grid, Not R-Tree

- Cell count known at init: `(die_width / cell_size) * (die_height / cell_size)`
- Routing segments are roughly uniform density
- O(1) cell lookup vs O(log n) tree traversal
- Bulk rebuild after rip-up is O(n), same as R-tree rebuild
- No tree rebalancing, no node splitting, no pointer chasing
- R-tree only wins for highly non-uniform density, which analog routing doesn't produce

---

## Table 4: MatchReport (SoA for Batch Analysis)

```zig
// src/router/pex_feedback.zig

pub const MatchReportDB = struct {
    // Per-group results (indexed by AnalogGroupIdx)
    group: []AnalogGroupIdx,
    passes: []bool,                // existence-based: could use DynamicBitSet
    r_ratio: []f32,                // max(R)/min(R) - 1.0
    c_ratio: []f32,                // max(C)/min(C) - 1.0
    length_ratio: []f32,           // max(len)/min(len) - 1.0
    via_delta: []i16,              // abs(max_vias - min_vias)
    coupling_delta: []f32,         // max(C_coup) - min(C_coup) [fF]
    thermal_gradient: []?f32,      // null if no thermal constraint

    len: u32,
    allocator: std.mem.Allocator,
};
```

### Existence-Based Pattern: `passes`

Instead of checking `if report.passes` in a loop, filter into two tables:

```zig
// After PEX analysis:
var passing_groups = std.ArrayList(AnalogGroupIdx).init(arena);
var failing_groups = std.ArrayList(AnalogGroupIdx).init(arena);

for (reports.group, reports.passes) |gid, pass| {
    if (pass) try passing_groups.append(gid)
    else try failing_groups.append(gid);
}

// Repair loop iterates only failing_groups — zero branch mispredictions
for (failing_groups.items) |gid| {
    try repairGroup(gid, reports);
}
```

---

## Table 5: ThermalMap (Dense 2D Grid)

```zig
// src/router/thermal.zig

pub const ThermalMap = struct {
    /// Temperature at each grid cell, in degrees C.
    /// Layout: row-major, cell(x,y) = temps[y * cols + x].
    temps: []f32,
    cols: u32,
    rows: u32,
    cell_size: f32,   // um — typically 10.0 (coarse for thermal)
    origin_x: f32,
    origin_y: f32,

    /// O(1) temperature query.
    pub inline fn query(self: *const ThermalMap, x: f32, y: f32) f32 {
        const cx: u32 = @intFromFloat(@max(0, (x - self.origin_x) / self.cell_size));
        const cy: u32 = @intFromFloat(@max(0, (y - self.origin_y) / self.cell_size));
        const idx = @min(cy, self.rows - 1) * self.cols + @min(cx, self.cols - 1);
        return self.temps[idx];
    }
};
```

### Cache Analysis

10mm die / 10um cell = 1000 x 1000 = 1M cells x 4B = 4MB. L3 resident.
Thermal queries during routing are spatially local (following the route), so L2 cache captures working set.

---

## Table 6: GuardRingDB (SoA)

```zig
// src/router/guard_ring.zig

pub const GuardRingType = enum(u8) {
    p_plus,
    n_plus,
    deep_nwell,
    substrate,
};

pub const GuardRingDB = struct {
    // ── Geometry (hot — DRC checks, obstacle marking) ──
    ring_type: []GuardRingType,   // 1B
    bbox_x1: []f32,              // 4B
    bbox_y1: []f32,              // 4B
    bbox_x2: []f32,              // 4B
    bbox_y2: []f32,              // 4B
    layer: []u8,                 // 1B
    net: []NetIdx,               // 4B
    width: []f32,                // 4B

    // ── Config (cold — read at setup) ──
    spacing: []f32,              // 4B
    contact_spacing: []f32,      // 4B
    isolation_target_db: []?f32, // 5B (optional)

    len: u16,    // u16 — max 65K guard rings
    capacity: u16,
    allocator: std.mem.Allocator,
};
```

---

## Table 7: ShieldDB (SoA)

```zig
// src/router/shield_router.zig

pub const ShieldDB = struct {
    // ── Geometry ──
    x1: []f32,
    y1: []f32,
    x2: []f32,
    y2: []f32,
    width: []f32,
    layer: []u8,
    shield_net: []NetIdx,     // ground/guard net
    signal_net: []NetIdx,     // net being shielded

    // ── Flags ──
    is_driven: []bool,        // driven guard vs grounded shield

    len: u32,
    capacity: u32,
    allocator: std.mem.Allocator,
};
```

---

## Table 8: LDE Constraints (SoA)

```zig
// src/router/lde.zig

pub const LDEConstraintDB = struct {
    device: []DeviceIdx,
    min_sa: []f32,    // um — min gate-to-STI source side
    min_sb: []f32,    // um — min gate-to-STI drain side
    max_sa: []f32,
    max_sb: []f32,
    sc_target: []f32, // um — well proximity target

    len: u32,
    capacity: u32,
    allocator: std.mem.Allocator,

    /// Generate keepout rects for spatial grid blocking.
    pub fn generateKeepouts(
        self: *const LDEConstraintDB,
        device_bboxes: anytype, // indexed by DeviceIdx
    ) ![]Rect {
        // For each constraint, compute bbox expanded by SA/SB
    }
};
```

---

## The Master Database: AnalogRouteDB

Owns all tables. Single point of allocation and deallocation.

```zig
// src/router/analog_db.zig

pub const AnalogRouteDB = struct {
    // ── Owned tables ──
    groups: AnalogGroupDB,
    segments: AnalogSegmentDB,
    spatial: SpatialGrid,
    shields: ShieldDB,
    guard_rings: GuardRingDB,
    thermal: ?ThermalMap,
    lde: LDEConstraintDB,
    match_reports: MatchReportDB,

    // ── Shared references (not owned) ──
    pdk: *const PdkConfig,

    // ── Arena for per-pass scratch data ──
    pass_arena: std.heap.ArenaAllocator,

    // ── Thread-local arenas (one per worker) ──
    thread_arenas: []std.heap.ArenaAllocator,

    pub fn init(
        allocator: std.mem.Allocator,
        pdk: *const PdkConfig,
        die_bbox: Rect,
        num_threads: u8,
    ) !AnalogRouteDB {
        var db: AnalogRouteDB = undefined;
        db.pdk = pdk;
        db.pass_arena = std.heap.ArenaAllocator.init(allocator);
        db.groups = try AnalogGroupDB.init(allocator, 64);  // pre-alloc 64 groups
        db.segments = try AnalogSegmentDB.init(allocator, 4096); // pre-alloc 4K segments
        db.spatial = try SpatialGrid.init(allocator, die_bbox, pdk);
        db.shields = try ShieldDB.init(allocator, 256);
        db.guard_rings = try GuardRingDB.init(allocator, 32);
        db.thermal = null;
        db.lde = try LDEConstraintDB.init(allocator, 128);
        db.match_reports = try MatchReportDB.init(allocator, 64);

        // Thread-local arenas
        db.thread_arenas = try allocator.alloc(std.heap.ArenaAllocator, num_threads);
        for (db.thread_arenas) |*ta| {
            ta.* = std.heap.ArenaAllocator.init(allocator);
        }

        return db;
    }

    pub fn deinit(self: *AnalogRouteDB) void {
        for (self.thread_arenas) |*ta| ta.deinit();
        // ... deinit all tables ...
        self.pass_arena.deinit();
    }

    /// Reset per-pass scratch between routing iterations.
    pub fn resetPass(self: *AnalogRouteDB) void {
        _ = self.pass_arena.reset(.retain_capacity);
        for (self.thread_arenas) |*ta| {
            _ = ta.reset(.retain_capacity);
        }
    }
};
```

---

## Memory Budget

Worst-case estimates for a moderately complex analog design:

| Table | Rows | Hot bytes/row | Hot total | Cold bytes/row | Cold total |
|-------|------|--------------|-----------|---------------|------------|
| Groups | 200 | 13 | 2.6 KB | 40 | 8 KB |
| Segments | 50K | 25 | 1.2 MB | 12 | 600 KB |
| Spatial grid | 500K cells | 6 | 3 MB | — | — |
| Shields | 5K | 25 | 125 KB | 1 | 5 KB |
| Guard rings | 100 | 26 | 2.6 KB | 13 | 1.3 KB |
| Thermal map | 1M cells | 4 | 4 MB | — | — |
| LDE constraints | 500 | 24 | 12 KB | — | — |
| Match reports | 200 | 24 | 4.8 KB | — | — |
| **Total** | — | — | **~8.4 MB** | — | **~615 KB** |

**Hot working set: ~8.4 MB** — fits comfortably in L3 (typical 6-30 MB).
**Cold data: ~615 KB** — only loaded on demand.

---

## Compile-Time Layout Assertions

Every SoA table should include layout assertions:

```zig
comptime {
    // Verify ID types are the expected size
    std.debug.assert(@sizeOf(AnalogGroupIdx) == 4);
    std.debug.assert(@sizeOf(SegmentIdx) == 4);
    std.debug.assert(@sizeOf(ShieldIdx) == 4);
    std.debug.assert(@sizeOf(GuardRingIdx) == 2);

    // Verify enum types fit in 1 byte
    std.debug.assert(@sizeOf(AnalogGroupType) == 1);
    std.debug.assert(@sizeOf(GuardRingType) == 1);
    std.debug.assert(@sizeOf(AnalogGroupDB.GroupStatus) == 1);
}
```

---

## Anti-Patterns Avoided

| Anti-Pattern | What We Do Instead |
|--------------|--------------------|
| `AnalogNetGroup` as single large struct (architecture doc) | SoA `AnalogGroupDB` table |
| `[]bool is_shielded` on every net | Separate `ShieldDB` table; membership = shielded |
| Pointer from `ShieldWire → AnalogNetGroup` | `shield_net: NetIdx` + lookup in `AnalogGroupDB` |
| `name: []const u8` per group (heap-scattered) | Interned `name_bytes` + `name_offsets` |
| Optional fields on every group (thermal, coupling, kelvin) | Cold split; null = not applicable |
| Per-segment `MatchedRoutingCost` struct | Computed on-the-fly during A*; never stored |
| `HashMap(NetIdx, SegmentIdx)` for net→segment lookup | Segments sorted by net; binary search or net_range index |
