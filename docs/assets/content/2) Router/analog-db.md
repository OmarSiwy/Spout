# Analog Database

## Overview

The analog database layer consists of four source files working together:

| File | Role |
|------|------|
| `analog_types.zig` | Canonical type definitions: IDs, enums, `Rect`, `Pin` |
| `analog_groups.zig` | `AnalogGroupDB` — SoA table of net group constraints |
| `analog_db.zig` | `AnalogSegmentDB`, `MatchReportDB`, `AnalogRouteDB` — segment storage and match results |
| `analog_tests.zig` | Integration tests covering all of the above plus `SpatialGrid` and `symmetric_steiner` |

Together these three implementation files constitute the complete persistent state of one analog routing pass. `AnalogGroupDB` describes what must be routed (constraints). `AnalogSegmentDB` stores what was actually routed (geometry). `MatchReportDB` stores how well it was routed (PEX match results). `AnalogRouteDB` is the master container owning all three with appropriate arenas for scratch memory.

---

## `analog_types.zig` — Type Definitions

### ID Types

All ID types are `enum(IntType)` with only `toInt` and `fromInt` methods exposed. Using enums for IDs prevents accidental mixing of integer values that have different semantic meaning — the compiler rejects passing a `SegmentIdx` where a `NetIdx` is expected.

| Type | Backing | Size | Description |
|------|---------|------|-------------|
| `NetIdx` | re-export from `core/types.zig` | — | Identifies a net by integer ordinal |
| `DeviceIdx` | re-export from `core/types.zig` | — | Identifies a device instance |
| `LayerIdx` | re-export from `core/types.zig` | — | Metal layer index |
| `AnalogGroupIdx` | `enum(u32)` | 4 B | Index into `AnalogGroupDB` |
| `SegmentIdx` | `enum(u32)` | 4 B | Index into a segment array |
| `ShieldIdx` | `enum(u32)` | 4 B | Index into `ShieldDB` |
| `GuardRingIdx` | `enum(u16)` | 2 B | Index into `GuardRingDB`; 16-bit because designs rarely have >65535 guard rings |
| `ThermalCellIdx` | `enum(u32)` | 4 B | Index into a thermal map cell array |
| `CentroidPatternIdx` | `enum(u32)` | 4 B | Index into a centroid pattern library |

All have compile-time size assertions enforced in a `comptime` block:
```zig
comptime {
    std.debug.assert(@sizeOf(AnalogGroupIdx) == 4);
    std.debug.assert(@sizeOf(SegmentIdx) == 4);
    // ... etc.
}
```

### Enums

#### `AnalogGroupType` (`enum(u8)`)

Discriminates how a group of nets must be routed:

| Variant | Value | Semantics |
|---------|-------|-----------|
| `differential` | 0 | Exactly 2 nets, routed with mirrored topology around a symmetry axis |
| `matched` | 1 | N≥2 nets, routed to have equal total R, C, wire length, and via count |
| `shielded` | 2 | 1 signal net with shield wires on the adjacent metal layer |
| `kelvin` | 3 | 2 nets: a force net (carries current) and a sense net (high-impedance voltage measurement), plus explicit `force_net` and `sense_net` pointers |
| `resistor_matched` | 4 | Resistor segments in common-centroid arrangement |
| `capacitor_array` | 5 | Unit capacitor array routing |

#### `GuardRingType` (`enum(u8)`)

| Variant | Value | Physical meaning |
|---------|-------|-----------------|
| `p_plus` | 0 | P+ diffusion ring, connected to VSS, isolates N-substrate currents |
| `n_plus` | 1 | N+ diffusion ring, connected to VDD, isolates P-well currents |
| `deep_nwell` | 2 | Deep N-well ring, provides triple-well isolation |
| `substrate` | 3 | Substrate tap ring |

#### `GroupStatus` (`enum(u8)`)

| Variant | Value | Description |
|---------|-------|-------------|
| `pending` | 0 | Not yet routed — initial state for all groups |
| `routing` | 1 | Currently being routed (used during parallel dispatch) |
| `routed` | 2 | Successfully routed and committed |
| `failed` | 3 | Routing failed (no path or PEX iterations exhausted) |

#### `RepairAction` (`enum(u8)`)

Describes what kind of repair the PEX feedback loop should apply to a failing group:

| Variant | Value | Applied when |
|---------|-------|-------------|
| `none` | 0 | Group already passes |
| `adjust_width` | 1 | R mismatch — widen or narrow wire segments |
| `adjust_layer` | 2 | C mismatch — move net to a different metal layer |
| `add_jog` | 3 | Wire length mismatch — insert a serpentine jog |
| `add_dummy_via` | 4 | Via count mismatch — insert a dummy up/down via pair |
| `rebalance_layer` | 5 | Coupling capacitance mismatch — reassign layers |

#### `RoutingResult` (`enum(u8)`)

| Variant | Value | Meaning |
|---------|-------|---------|
| `success` | 0 | All constraints met |
| `mismatch_exceeded` | 1 | PEX loop converged but mismatch is above tolerance |
| `no_path` | 2 | A* found no feasible route |
| `max_iterations` | 3 | PEX iteration limit reached |

#### `SymmetryAxis` (`enum(u8)`)

| Variant | Value | Meaning |
|---------|-------|---------|
| `x` | 0 | Horizontal axis — mirrors across the Y direction |
| `y` | 1 | Vertical axis — mirrors across the X direction |

### `Rect`

```zig
pub const Rect = struct {
    x1: f32,  // left edge
    y1: f32,  // bottom edge
    x2: f32,  // right edge
    y2: f32,  // top edge
    ...
};
```

All coordinates are in micrometers. Eight methods:

| Method | Return | Algorithm |
|--------|--------|-----------|
| `width()` | `f32` | `x2 - x1` |
| `height()` | `f32` | `y2 - y1` |
| `area()` | `f32` | `width() * height()` |
| `centerX()` | `f32` | `(x1 + x2) * 0.5` |
| `centerY()` | `f32` | `(y1 + y2) * 0.5` |
| `overlaps(other)` | `bool` | Axis-aligned intersection: `x1 < other.x2 and x2 > other.x1 and y1 < other.y2 and y2 > other.y1` |
| `overlapsWithMargin(other, margin)` | `bool` | Same but expands `self` by `margin` on all sides before the intersection test |
| `expand(amount)` | `Rect` | Returns new `Rect` with each edge moved outward by `amount` |
| `union_(other)` | `Rect` | Bounding box of both rects |
| `containsPoint(x, y)` | `bool` | Closed-half-open: `x >= x1 and x < x2 and y >= y1 and y < y2` |

### `Pin`

```zig
pub const Pin = struct {
    x: f32,
    y: f32,
    net: NetIdx,
    name: []const u8,
};
```

A named connection point used as routing targets. `name` is a string slice (caller-owned, not copied). `x` and `y` are world coordinates in micrometers.

---

## `analog_groups.zig` — `AnalogGroupDB`

### Design Rationale

`AnalogGroupDB` is a Structure-of-Arrays table. The fields are divided into three tiers by access frequency:

- **Hot fields** — touched every routing iteration (scheduler, A* cost, tolerance checks). Packed together for cache efficiency.
- **Net membership** — accessed when dispatching routing; stored in a flat pool with per-group range descriptors.
- **Cold fields** — only accessed during setup and reporting. May reside in L3 or DRAM during routing.

### `AddGroupRequest`

The input record used to add a group to the DB:

| Field | Type | Description |
|-------|------|-------------|
| `name` | `[]const u8` | Human-readable group name (e.g., `"diff_pair_1"`). Copied into the internal `name_bytes` pool. |
| `group_type` | `AnalogGroupType` | Type of analog matching constraint. |
| `nets` | `[]const NetIdx` | Slice of net IDs belonging to this group. Length requirements vary by type. |
| `tolerance` | `f32` | Maximum allowed mismatch ratio (0.0–1.0). E.g., `0.05` = 5% maximum mismatch. |
| `preferred_layer` | `?LayerIdx` | If non-null, the router will try to route this group on this metal layer. |
| `route_priority` | `u8` | Lower values route first. Priority 0 is highest priority. |
| `thermal_tolerance` | `?f32` | If non-null, maximum allowed temperature difference between matched nets (degrees Celsius). |
| `coupling_tolerance` | `?f32` | If non-null, maximum allowed coupling capacitance difference (femtofarads). |
| `shield_net` | `?NetIdx` | For shielded groups: the net to connect shield wires to (usually VSS). |
| `force_net` | `?NetIdx` | For Kelvin groups: the force (current-carrying) net. |
| `sense_net` | `?NetIdx` | For Kelvin groups: the sense (voltage-measurement) net. |
| `centroid_pattern` | `?CentroidPatternIdx` | For resistor/capacitor arrays: index into a centroid pattern library. |

### `AddGroupError`

```zig
pub const AddGroupError = error{
    InvalidNetCount,
    InvalidTolerance,
    DeviceTypeMismatch,
    MissingKelvinNets,
    GroupTableFull,
    OutOfMemory,
};
```

These are returned by `addGroupWithValidation`. `addGroup` is an alias that calls `addGroupWithValidation`.

### `AnalogGroupDB` Fields

**Hot fields** (iterated every routing iteration):

| Field | Type | Per-entry size | Description |
|-------|------|----------------|-------------|
| `group_type` | `[]AnalogGroupType` | 1 B | Routing mode for this group |
| `route_priority` | `[]u8` | 1 B | Sort key for routing order |
| `tolerance` | `[]f32` | 4 B | Matching tolerance |
| `preferred_layer` | `[]?LayerIdx` | 3 B (u16 + tag) | Optional preferred metal layer |
| `status` | `[]GroupStatus` | 1 B | Current routing state |

**Net membership:**

| Field | Type | Description |
|-------|------|-------------|
| `net_range_start` | `[]u32` | Index into `net_pool` where group `i`'s nets begin |
| `net_count` | `[]u8` | Number of nets for group `i` (max 255) |
| `net_pool` | `[]NetIdx` | Flat pool of all net IDs across all groups. Group `i`'s nets are `net_pool[net_range_start[i] .. net_range_start[i] + net_count[i]]`. |

The `net_pool` starts at capacity `4 × group_capacity` (assuming average 4 nets per group) and doubles when exhausted.

**Cold fields:**

| Field | Type | Description |
|-------|------|-------------|
| `name_offsets` | `[]u32` | Byte offset into `name_bytes` for group `i`'s name |
| `name_bytes` | `[]u8` | Concatenated name strings (no null terminator, length inferred from next name's offset) |
| `thermal_tolerance` | `[]?f32` | Per-group thermal constraint, null if none |
| `coupling_tolerance` | `[]?f32` | Per-group coupling constraint, null if none |
| `shield_net` | `[]?NetIdx` | Shield net for shielded groups, null otherwise |
| `force_net` | `[]?NetIdx` | Force net for Kelvin groups |
| `sense_net` | `[]?NetIdx` | Sense net for Kelvin groups |
| `centroid_pattern` | `[]?CentroidPatternIdx` | Pattern index for resistor/cap arrays |

**Bookkeeping:**

| Field | Type | Description |
|-------|------|-------------|
| `len` | `u32` | Number of groups currently stored |
| `capacity` | `u32` | Allocated slot count |
| `name_bytes_len` | `u32` | Used bytes in `name_bytes` |
| `allocator` | `std.mem.Allocator` | Owns all arrays |

### `AnalogGroupDB` API

#### `init`

```zig
pub fn init(allocator: std.mem.Allocator, capacity: u32) !AnalogGroupDB
```

Pre-allocates all SoA arrays to `capacity`. Hot fields are allocated at `capacity` entries. Net pool starts at `capacity × 4`. Name bytes buffer starts at `capacity × 32`. All `status` entries are initialized to `.pending`.

#### `deinit`

```zig
pub fn deinit(self: *AnalogGroupDB) void
```

Frees all 16 allocated slices in the correct order. Must be called exactly once.

#### `addGroupWithValidation`

```zig
pub fn addGroupWithValidation(
    self: *AnalogGroupDB,
    req: AddGroupRequest,
) AddGroupError!void
```

**Validation rules:**

| Group type | Net count requirement | Additional |
|------------|----------------------|-----------|
| `differential` | exactly 2 | — |
| `matched`, `resistor_matched`, `capacitor_array` | >= 2 | — |
| `shielded` | exactly 1 | — |
| `kelvin` | exactly 2 | `force_net != null && sense_net != null` |

**Tolerance check:** `0.0 <= tolerance <= 1.0`, else `error.InvalidTolerance`.

**Capacity check:** if `self.len >= self.capacity`, returns `error.GroupTableFull` (no dynamic growth of the per-group arrays — caller must allocate with adequate capacity).

**Pool growth:** `growNetPoolIfNeeded` and `growNameBytesIfNeeded` grow their respective arrays by doubling when needed; these can return `error.OutOfMemory`.

**Write protocol:** All field writes happen before `self.len += 1`. This ensures that if an error occurs partway through writing a group's fields, the group is not visible to readers.

#### `addGroup`

```zig
pub fn addGroup(self: *AnalogGroupDB, req: AddGroupRequest) !void
```

Alias for `addGroupWithValidation`. The `!void` error set is the union of `AddGroupError` and `error.OutOfMemory`.

#### `netsForGroup`

```zig
pub fn netsForGroup(self: *const AnalogGroupDB, idx: u32) []const NetIdx
```

Returns a slice into `net_pool` for group `idx`. The slice spans `net_pool[net_range_start[idx] .. net_range_start[idx] + net_count[idx]]`. O(1). No allocation.

#### `sortedByPriority`

```zig
pub fn sortedByPriority(
    self: *const AnalogGroupDB,
    allocator: std.mem.Allocator,
) ![]AnalogGroupIdx
```

Allocates and returns a slice of `AnalogGroupIdx` values sorted ascending by `route_priority`. Uses `std.mem.sort` with a context closure. The caller owns the returned slice and must free it.

**Why sort externally?** Keeping the DB unsorted allows O(1) insertion. The router calls `sortedByPriority` once at the start of a routing pass.

### Internal Helpers

#### `getNetPoolLen`

Computes the logical write cursor in `net_pool` as `net_range_start[last] + net_count[last]`. Returns 0 if `len == 0`.

#### `getNameBytesLen` / `setNameBytesLen`

Getter and setter for `name_bytes_len`. Encapsulated to allow future atomicity if threading is added.

#### `growNetPoolIfNeeded`

Doubles the `net_pool` slice if `current_len + needed > net_pool.len`. Uses `allocator.realloc`.

#### `growNameBytesIfNeeded`

Same pattern for the `name_bytes` buffer.

### `GroupDependencyGraph`

Built from an `AnalogGroupDB` to determine which groups can route in parallel.

**Fields:**

| Field | Type | Description |
|-------|------|-------------|
| `adjacency` | `[]std.ArrayListUnmanaged(AnalogGroupIdx)` | For each group `i`, a list of groups that conflict with `i` |
| `num_groups` | `u32` | Total number of groups |
| `allocator` | `std.mem.Allocator` | Used for both the outer array and each inner list |

#### `GroupDependencyGraph.build`

```zig
pub fn build(
    allocator: std.mem.Allocator,
    groups: *const AnalogGroupDB,
    pin_bboxes: []const Rect,
    margin: f32,
) !GroupDependencyGraph
```

**Algorithm.** O(groups²) all-pairs conflict check:

For each pair `(i, j)`:
1. **Shared net check:** iterate the nets of group `i` and group `j`. If any `ni.toInt() == nj.toInt()`, the groups conflict.
2. **Bounding box check:** if both indices are within `pin_bboxes`, check `bboxes[i].overlapsWithMargin(bboxes[j], margin)`.

If either check is positive, add `j` to `adjacency[i]` and `i` to `adjacency[j]`.

The `margin` parameter is typically `2 × max_spacing` to capture groups that have closely-adjacent but not identical bounding boxes.

#### `groupsConflictBetween`

```zig
pub fn groupsConflictBetween(
    groups: *const AnalogGroupDB,
    bboxes: []const Rect,
    i: AnalogGroupIdx,
    j: AnalogGroupIdx,
    margin: f32,
) bool
```

Public helper that calls the private `groupsConflict` for a specific pair. Used by higher-level routing logic that needs to check individual pairs without building the full graph.

---

## `analog_db.zig` — Segment and Report Tables

### `SegmentFlags`

```zig
pub const SegmentFlags = packed struct(u8) {
    is_shield: bool = false,
    is_dummy_via: bool = false,
    is_jog: bool = false,
    _padding: u5 = 0,
};
```

A packed 8-bit flag word stored per segment. Three semantic bits:

- `is_shield`: segment is a shield wire, not a signal wire.
- `is_dummy_via`: segment is a via inserted for via-count matching, not for connectivity.
- `is_jog`: segment is a wire-length-equalizing jog, not a direct routing segment.

These flags are preserved when segments are exported to `RouteArrays` via `toRouteArrays`.

### `AnalogSegmentDB`

The primary output of analog routing. Stores all routed wire segments as parallel SoA arrays.

**Geometry columns (hot — accessed by DRC and PEX):**

| Field | Type | Description |
|-------|------|-------------|
| `x1` | `[]f32` | Segment start X, µm |
| `y1` | `[]f32` | Segment start Y, µm |
| `x2` | `[]f32` | Segment end X, µm |
| `y2` | `[]f32` | Segment end Y, µm |
| `width` | `[]f32` | Wire width, µm |
| `layer` | `[]u8` | Metal layer (1 = Met1, 2 = Met2, etc.) |
| `net` | `[]NetIdx` | Net ownership |

**Analog metadata (warm — accessed during PEX and match computation):**

| Field | Type | Description |
|-------|------|-------------|
| `group` | `[]AnalogGroupIdx` | Which analog group produced this segment |
| `segment_flags` | `[]SegmentFlags` | Shield / dummy via / jog flags |

**PEX cache (cold — written after PEX extraction, read during match report generation):**

| Field | Type | Description |
|-------|------|-------------|
| `resistance` | `[]f32` | Wire resistance in ohms, computed from sheet resistance and geometry |
| `capacitance` | `[]f32` | Capacitance to substrate in femtofarads |
| `coupling_cap` | `[]f32` | Coupling capacitance to nearest neighbor net, fF |

**Bookkeeping:**

| Field | Type | Description |
|-------|------|-------------|
| `len` | `u32` | Number of valid segments |
| `capacity` | `u32` | Allocated slot count |
| `allocator` | `std.mem.Allocator` | Owns all arrays |

#### `AppendParams`

```zig
pub const AppendParams = struct {
    x1: f32, y1: f32, x2: f32, y2: f32,
    width: f32, layer: u8,
    net: NetIdx, group: AnalogGroupIdx,
    flags: SegmentFlags = .{},
};
```

Named-fields input record for `append`. The PEX columns (`resistance`, `capacitance`, `coupling_cap`) are always initialized to `0.0` and filled in later by the PEX extractor.

#### `AnalogSegmentDB.init`

```zig
pub fn init(allocator: std.mem.Allocator, cap: u32) !AnalogSegmentDB
```

Allocates all 12 columns at `cap` entries each. Returns partially-initialized DB on error (all fields present, `len = 0`). The PEX columns are not zeroed here — they are zeroed per-segment in `append`.

#### `AnalogSegmentDB.deinit`

```zig
pub fn deinit(self: *AnalogSegmentDB) void
```

Guards against `capacity == 0` (zero-capacity DBs have empty slices that must not be freed). Frees all 12 columns.

#### `AnalogSegmentDB.append`

```zig
pub fn append(self: *AnalogSegmentDB, p: AppendParams) !void
```

If `len >= capacity`, calls `grow()` to double capacity. Then writes all 12 columns at index `len` and increments `len`. PEX columns are explicitly set to `0.0`.

#### `AnalogSegmentDB.grow`

```zig
fn grow(self: *AnalogSegmentDB) !void
```

Doubles capacity (minimum 256 on first grow). Calls `allocator.realloc` on all 12 column slices. On partial failure, the already-reallocated slices have grown and the original capacity is invalid — the function is intended to be called in non-fallible paths (the router is expected to pre-allocate adequately).

#### `AnalogSegmentDB.toRouteArrays`

```zig
pub fn toRouteArrays(self: *const AnalogSegmentDB, out: *RouteArrays) !void
```

Copies the DB's geometry and flag columns into a `RouteArrays` (the universal segment format consumed by downstream tools — DRC, GDS export, PEX). The copy is performed with `@memcpy` for all geometry columns, and a loop for flags (which require field-by-field translation because `RouteArrays.flags` may have a different packed layout).

**Zero-copy design intent.** The column layout of `AnalogSegmentDB` matches `RouteArrays` exactly so that future optimization could eliminate the copy entirely (e.g., by making `RouteArrays` point directly into the DB's arrays). The current implementation uses `@memcpy` as a safe intermediate step.

#### `AnalogSegmentDB.removeGroup`

```zig
pub fn removeGroup(self: *AnalogSegmentDB, gid: AnalogGroupIdx) void
```

In-place compaction: iterates all segments with a read index and write index, skipping segments whose `group` matches `gid`. All 12 columns are moved together. O(n). Called during rip-up-and-reroute when a group's routing is discarded.

#### `AnalogSegmentDB.netLength`

```zig
pub fn netLength(self: *const AnalogSegmentDB, net: NetIdx) f32
```

Returns the total Manhattan wire length of all segments on a given net: `Σ |x2−x1| + |y2−y1|`. Zero-length segments (vias, dummy vias) contribute zero. O(n).

#### `AnalogSegmentDB.viaCount`

```zig
pub fn viaCount(self: *const AnalogSegmentDB, net: NetIdx) u32
```

Counts segments on `net` where `x1 == x2 && y1 == y2` (zero-length = via representation). O(n). Called by the match reporter to compute via count parity between matched nets.

---

### `MatchReportDB`

Stores the results of one PEX feedback iteration for each analog group.

**Columns:**

| Field | Type | Description |
|-------|------|-------------|
| `group` | `[]AnalogGroupIdx` | Which group this report covers |
| `passes` | `[]bool` | True if all metrics are within tolerance |
| `r_ratio` | `[]f32` | `|R_a − R_b| / max(R_a, R_b)` — resistance mismatch ratio |
| `c_ratio` | `[]f32` | `|C_a − C_b| / max(C_a, C_b)` — capacitance mismatch ratio |
| `length_ratio` | `[]f32` | `|L_a − L_b| / max(L_a, L_b)` — wire length mismatch ratio |
| `via_delta` | `[]i16` | `via_count_a − via_count_b` — signed via count difference |
| `coupling_delta` | `[]f32` | Coupling capacitance difference to neighbors (fF) |
| `len` | `u32` | Number of reports stored |
| `capacity` | `u32` | Allocated slots |
| `allocator` | `std.mem.Allocator` | Owns all arrays |

#### `ReportParams`

```zig
pub const ReportParams = struct {
    group: AnalogGroupIdx,
    passes: bool,
    r_ratio: f32,
    c_ratio: f32,
    length_ratio: f32,
    via_delta: i16,
    coupling_delta: f32,
};
```

Input record for `append`.

#### `MatchReportDB.init`

```zig
pub fn init(allocator: std.mem.Allocator, cap: u32) !MatchReportDB
```

Allocates all 7 columns at `cap` entries.

#### `MatchReportDB.deinit`

```zig
pub fn deinit(self: *MatchReportDB) void
```

Guards against `capacity == 0`. Frees all 7 columns.

#### `MatchReportDB.ensureCapacity`

```zig
pub fn ensureCapacity(self: *MatchReportDB, new_cap: u32) !void
```

If `new_cap > self.capacity`, reallocates all 7 columns via `realloc`. No-op if already large enough.

#### `MatchReportDB.append`

```zig
pub fn append(self: *MatchReportDB, p: ReportParams) !void
```

If `len >= capacity`, calls `ensureCapacity(capacity * 2)`. Writes all 7 columns and increments `len`.

#### `MatchReportDB.clearGroupReports`

```zig
pub fn clearGroupReports(self: *MatchReportDB, gid: AnalogGroupIdx) void
```

In-place compaction removing all reports for group `gid`. Same read/write cursor pattern as `AnalogSegmentDB.removeGroup`. Called on rip-up so that stale match results do not interfere with the next PEX iteration.

---

### `AnalogRouteDB`

The master container that owns and coordinates all sub-databases.

**Fields:**

| Field | Type | Description |
|-------|------|-------------|
| `segments` | `AnalogSegmentDB` | All routed wire segments. Initial capacity 4096. |
| `match_reports` | `MatchReportDB` | PEX match results. Initial capacity 64. |
| `pdk` | `*const PdkConfig` | Non-owning pointer to PDK configuration. Used by PEX and DRC subsystems. |
| `die_bbox` | `Rect` | Die bounding box. Passed to spatial grid and guard ring inserter. |
| `pass_arena` | `std.heap.ArenaAllocator` | Arena reset between PEX iterations (`resetPass`). Used for temporary per-pass allocations (net result structs, match report intermediates). |
| `thread_arenas` | `[]std.heap.ArenaAllocator` | One arena per routing thread, for A* open/closed sets and scratch. Reset between wavefronts. |
| `allocator` | `std.mem.Allocator` | Root allocator. Owns `thread_arenas` slice and the two sub-databases. |

#### `AnalogRouteDB.init`

```zig
pub fn init(
    allocator: std.mem.Allocator,
    pdk: *const PdkConfig,
    die_bbox: Rect,
    num_threads: u8,
) !AnalogRouteDB
```

**Algorithm:**
1. Clamp `num_threads` to at least 1.
2. Allocate `thread_arenas` slice of `nt` `ArenaAllocator` instances.
3. Initialize each thread arena: `ta.* = std.heap.ArenaAllocator.init(allocator)`.
4. Initialize `segments` with capacity 4096.
5. Initialize `match_reports` with capacity 64.
6. Initialize `pass_arena`.
7. Return.

Initial capacity 4096 is large enough for most small/medium analog circuits without reallocating.

#### `AnalogRouteDB.deinit`

```zig
pub fn deinit(self: *AnalogRouteDB) void
```

Deinits thread arenas (calls `ta.deinit()` for each), frees the thread arenas slice, deinits `pass_arena`, deinits `match_reports`, deinits `segments`.

#### `AnalogRouteDB.resetPass`

```zig
pub fn resetPass(self: *AnalogRouteDB) void
```

Resets `pass_arena` and all thread arenas with `.retain_capacity` — the underlying memory pages are kept but the arena's allocation cursor is reset to zero. This allows PEX iteration scratch memory to be reused without re-allocating. Does not touch `segments` or `match_reports` — those persist across passes.

**Invariant.** After `resetPass`, the `pass_arena` and thread arenas are empty but their backing memory is retained. The `segments.len` and `match_reports.len` are unchanged. The caller is responsible for calling `segments.removeGroup` and `match_reports.clearGroupReports` for failing groups before re-routing them.

---

## Lifetime and Ownership Summary

```
AnalogRouteDB
  ├─ allocator  (external, not owned)
  ├─ pdk        (external, not owned)
  ├─ segments   (owned — all 12 SoA arrays)
  ├─ match_reports (owned — all 7 SoA arrays)
  ├─ pass_arena (owned)
  └─ thread_arenas[] (owned — each arena owns its blocks)
```

`AnalogGroupDB` is typically a separate object not embedded in `AnalogRouteDB`. It is owned by the caller and passed by pointer to routing functions.

---

## Relationship Between Types

```
AnalogGroupDB  →  describes what to route (constraints, net groups)
       ↓
MatchedRouter  →  routes the groups using A* + symmetric Steiner
       ↓
AnalogSegmentDB →  stores what was routed (geometry, flags)
       ↓
PEX extractor  →  fills resistance/capacitance/coupling_cap columns
       ↓
MatchReportDB  →  stores how well it was routed (ratios, pass/fail)
       ↓
RepairAction   →  feedback: what to change for the next iteration
```

The `AnalogRouteDB` is the root container. The `AnalogGroupDB` lives beside it, not inside it. The `SpatialGrid` is rebuilt from `AnalogSegmentDB.x1/y1/x2/y2` arrays between routing wavefronts.

---

## Tests

`analog_db.zig` contains 10 inline tests. `analog_groups.zig` contains 15 inline tests. `analog_types.zig` contains 14 inline tests. `analog_tests.zig` duplicates many of these as a combined integration test file.

Key tests:

| Test | File | Verifies |
|------|------|---------|
| `AnalogSegmentDB init and deinit` | analog_db | Zero len, correct capacity |
| `AnalogSegmentDB append segment` | analog_db | All columns written correctly |
| `AnalogSegmentDB append auto-grows` | analog_db | grow() doubles capacity automatically |
| `AnalogSegmentDB toRouteArrays lossless` | analog_db | All 7 geometry+net columns match after export |
| `AnalogSegmentDB removeGroup` | analog_db | 50 of 100 segments removed, remaining are correct net |
| `AnalogSegmentDB netLength` | analog_db | Two segments totaling 15 µm measured correctly |
| `AnalogSegmentDB viaCount` | analog_db | 3 zero-length segments counted, 2 non-zero excluded |
| `MatchReportDB append and read` | analog_db | All 7 report fields round-trip correctly |
| `AnalogRouteDB init and deinit` | analog_db | 4 thread arenas created |
| `AnalogRouteDB resetPass` | analog_db | Segments retained after pass reset |
| `reject differential group with odd net count` | analog_groups | `error.InvalidNetCount` returned |
| `kelvin group requires force and sense nets` | analog_groups | `error.MissingKelvinNets` returned |
| `groups sorted by priority for routing order` | analog_groups | sortedByPriority returns [0,1,2] order |
| `GroupDependencyGraph detects shared net conflict` | analog_groups | Shared net 1 creates bidirectional adjacency |
