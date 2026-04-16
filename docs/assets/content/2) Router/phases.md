# Implementation Phases

Spout's analog router is built in eleven sequential phases. Each phase produces a self-contained testable increment; later phases depend on earlier ones but no phase modifies the public API of a previous phase. The plan targets Zig 0.15, the SKY130 PDK, and prioritises accuracy over performance.

```svg
<svg viewBox="0 0 900 560" xmlns="http://www.w3.org/2000/svg" style="background:#060C18;border-radius:8px;display:block;max-width:100%">
  <defs>
    <marker id="ph-arr" markerWidth="7" markerHeight="5" refX="7" refY="2.5" orient="auto">
      <polygon points="0 0, 7 2.5, 0 5" fill="#00C4E8"/>
    </marker>
  </defs>

  <text x="450" y="28" text-anchor="middle" fill="#B8D0E8" font-family="monospace" font-size="14" font-weight="bold">11-Phase Build Sequence</text>

  <!-- Phase boxes: 2 rows of 5, then 1 bottom center -->
  <!-- Row 1: phases 1-5 -->
  <!-- Phase 1 -->
  <rect x="30"  y="50" width="140" height="56" rx="5" fill="#09111F" stroke="#00C4E8" stroke-width="1.5"/>
  <text x="100" y="70"  text-anchor="middle" fill="#00C4E8"  font-family="monospace" font-size="10" font-weight="bold">Phase 1</text>
  <text x="100" y="84"  text-anchor="middle" fill="#B8D0E8"  font-family="monospace" font-size="9">Core Types +</text>
  <text x="100" y="97"  text-anchor="middle" fill="#B8D0E8"  font-family="monospace" font-size="9">AnalogRouteDB</text>

  <!-- Phase 2 -->
  <rect x="195" y="50" width="140" height="56" rx="5" fill="#09111F" stroke="#1E88E5" stroke-width="1.5"/>
  <text x="265" y="70"  text-anchor="middle" fill="#1E88E5"  font-family="monospace" font-size="10" font-weight="bold">Phase 2</text>
  <text x="265" y="84"  text-anchor="middle" fill="#B8D0E8"  font-family="monospace" font-size="9">Spatial Grid</text>
  <text x="265" y="97"  text-anchor="middle" fill="#B8D0E8"  font-family="monospace" font-size="9">O(1) DRC</text>

  <!-- Phase 3 -->
  <rect x="360" y="50" width="140" height="56" rx="5" fill="#09111F" stroke="#43A047" stroke-width="1.5"/>
  <text x="430" y="70"  text-anchor="middle" fill="#43A047"  font-family="monospace" font-size="10" font-weight="bold">Phase 3</text>
  <text x="430" y="84"  text-anchor="middle" fill="#B8D0E8"  font-family="monospace" font-size="9">AnalogGroup</text>
  <text x="430" y="97"  text-anchor="middle" fill="#B8D0E8"  font-family="monospace" font-size="9">Database</text>

  <!-- Phase 4 -->
  <rect x="525" y="50" width="140" height="56" rx="5" fill="#09111F" stroke="#AB47BC" stroke-width="1.5"/>
  <text x="595" y="70"  text-anchor="middle" fill="#AB47BC"  font-family="monospace" font-size="10" font-weight="bold">Phase 4</text>
  <text x="595" y="84"  text-anchor="middle" fill="#B8D0E8"  font-family="monospace" font-size="9">Matched Router</text>
  <text x="595" y="97"  text-anchor="middle" fill="#B8D0E8"  font-family="monospace" font-size="9">SymmetricSteiner</text>

  <!-- Phase 5 -->
  <rect x="690" y="50" width="180" height="56" rx="5" fill="#09111F" stroke="#FB8C00" stroke-width="1.5"/>
  <text x="780" y="70"  text-anchor="middle" fill="#FB8C00"  font-family="monospace" font-size="10" font-weight="bold">Phase 5</text>
  <text x="780" y="84"  text-anchor="middle" fill="#B8D0E8"  font-family="monospace" font-size="9">Shield Router</text>
  <text x="780" y="97"  text-anchor="middle" fill="#B8D0E8"  font-family="monospace" font-size="9">routeShielded</text>

  <!-- Row 1 arrows -->
  <line x1="170" y1="78" x2="193" y2="78" stroke="#00C4E8" stroke-width="1.3" marker-end="url(#ph-arr)"/>
  <line x1="335" y1="78" x2="358" y2="78" stroke="#00C4E8" stroke-width="1.3" marker-end="url(#ph-arr)"/>
  <line x1="500" y1="78" x2="523" y2="78" stroke="#00C4E8" stroke-width="1.3" marker-end="url(#ph-arr)"/>
  <line x1="665" y1="78" x2="688" y2="78" stroke="#00C4E8" stroke-width="1.3" marker-end="url(#ph-arr)"/>

  <!-- Row 2: phases 6-10 -->
  <!-- Phase 6 -->
  <rect x="30"  y="170" width="140" height="56" rx="5" fill="#09111F" stroke="#EF5350" stroke-width="1.5"/>
  <text x="100" y="190" text-anchor="middle" fill="#EF5350"  font-family="monospace" font-size="10" font-weight="bold">Phase 6</text>
  <text x="100" y="204" text-anchor="middle" fill="#B8D0E8"  font-family="monospace" font-size="9">Guard Ring</text>
  <text x="100" y="217" text-anchor="middle" fill="#B8D0E8"  font-family="monospace" font-size="9">Inserter</text>

  <!-- Phase 7 -->
  <rect x="195" y="170" width="140" height="56" rx="5" fill="#09111F" stroke="#00C4E8" stroke-width="1.5"/>
  <text x="265" y="190" text-anchor="middle" fill="#00C4E8"  font-family="monospace" font-size="10" font-weight="bold">Phase 7</text>
  <text x="265" y="204" text-anchor="middle" fill="#B8D0E8"  font-family="monospace" font-size="9">Thermal Router</text>
  <text x="265" y="217" text-anchor="middle" fill="#B8D0E8"  font-family="monospace" font-size="9">ThermalMap</text>

  <!-- Phase 8 -->
  <rect x="360" y="170" width="140" height="56" rx="5" fill="#09111F" stroke="#1E88E5" stroke-width="1.5"/>
  <text x="430" y="190" text-anchor="middle" fill="#1E88E5"  font-family="monospace" font-size="10" font-weight="bold">Phase 8</text>
  <text x="430" y="204" text-anchor="middle" fill="#B8D0E8"  font-family="monospace" font-size="9">LDE Router</text>
  <text x="430" y="217" text-anchor="middle" fill="#B8D0E8"  font-family="monospace" font-size="9">WPE Keepouts</text>

  <!-- Phase 9 -->
  <rect x="525" y="170" width="140" height="56" rx="5" fill="#09111F" stroke="#43A047" stroke-width="1.5"/>
  <text x="595" y="190" text-anchor="middle" fill="#43A047"  font-family="monospace" font-size="10" font-weight="bold">Phase 9</text>
  <text x="595" y="204" text-anchor="middle" fill="#B8D0E8"  font-family="monospace" font-size="9">PEX Feedback</text>
  <text x="595" y="217" text-anchor="middle" fill="#B8D0E8"  font-family="monospace" font-size="9">Loop (5 iter max)</text>

  <!-- Phase 10 -->
  <rect x="690" y="170" width="180" height="56" rx="5" fill="#09111F" stroke="#AB47BC" stroke-width="1.5"/>
  <text x="780" y="190" text-anchor="middle" fill="#AB47BC"  font-family="monospace" font-size="10" font-weight="bold">Phase 10</text>
  <text x="780" y="204" text-anchor="middle" fill="#B8D0E8"  font-family="monospace" font-size="9">Thread Pool</text>
  <text x="780" y="217" text-anchor="middle" fill="#B8D0E8"  font-family="monospace" font-size="9">Parallel Dispatch</text>

  <!-- Row 2 arrows -->
  <line x1="170" y1="198" x2="193" y2="198" stroke="#00C4E8" stroke-width="1.3" marker-end="url(#ph-arr)"/>
  <line x1="335" y1="198" x2="358" y2="198" stroke="#00C4E8" stroke-width="1.3" marker-end="url(#ph-arr)"/>
  <line x1="500" y1="198" x2="523" y2="198" stroke="#00C4E8" stroke-width="1.3" marker-end="url(#ph-arr)"/>
  <line x1="665" y1="198" x2="688" y2="198" stroke="#00C4E8" stroke-width="1.3" marker-end="url(#ph-arr)"/>

  <!-- Row-to-row connector Phase 5 → Phase 6 -->
  <line x1="780" y1="106" x2="780" y2="130" stroke="#3E5E80" stroke-width="1" stroke-dasharray="4,2"/>
  <line x1="780" y1="130" x2="100" y2="130" stroke="#3E5E80" stroke-width="1" stroke-dasharray="4,2"/>
  <line x1="100" y1="130" x2="100" y2="168" stroke="#3E5E80" stroke-width="1" stroke-dasharray="4,2" marker-end="url(#ph-arr)"/>

  <!-- Phase 11 centered -->
  <rect x="330" y="280" width="240" height="56" rx="5" fill="#09111F" stroke="#FB8C00" stroke-width="2"/>
  <text x="450" y="300" text-anchor="middle" fill="#FB8C00"  font-family="monospace" font-size="11" font-weight="bold">Phase 11</text>
  <text x="450" y="315" text-anchor="middle" fill="#B8D0E8"  font-family="monospace" font-size="9">Integration + Signoff</text>
  <text x="450" y="328" text-anchor="middle" fill="#B8D0E8"  font-family="monospace" font-size="9">AnalogRouter public API + lib.zig export</text>

  <!-- Phase 10 → 11 -->
  <line x1="780" y1="226" x2="780" y2="258" stroke="#3E5E80" stroke-width="1" stroke-dasharray="4,2"/>
  <line x1="780" y1="258" x2="572" y2="258" stroke="#3E5E80" stroke-width="1" stroke-dasharray="4,2"/>
  <line x1="572" y1="258" x2="572" y2="278" stroke="#3E5E80" stroke-width="1" stroke-dasharray="4,2" marker-end="url(#ph-arr)"/>

  <!-- File map row -->
  <text x="450" y="370" text-anchor="middle" fill="#3E5E80" font-family="monospace" font-size="10" font-weight="bold">New Files per Phase</text>

  <rect x="30" y="382" width="840" height="150" rx="5" fill="#09111F" stroke="#14263E" stroke-width="1"/>

  <text x="50"  y="400" fill="#00C4E8"  font-family="monospace" font-size="9" font-weight="bold">Ph 1</text>
  <text x="80"  y="400" fill="#B8D0E8"  font-family="monospace" font-size="9">analog_types.zig  analog_db.zig  spatial_grid.zig  analog_tests.zig</text>

  <text x="50"  y="416" fill="#1E88E5"  font-family="monospace" font-size="9" font-weight="bold">Ph 2</text>
  <text x="80"  y="416" fill="#B8D0E8"  font-family="monospace" font-size="9">spatial_grid.zig (extend)  SpatialDrcChecker replaces InlineDrcChecker</text>

  <text x="50"  y="432" fill="#43A047"  font-family="monospace" font-size="9" font-weight="bold">Ph 3</text>
  <text x="80"  y="432" fill="#B8D0E8"  font-family="monospace" font-size="9">analog_groups.zig  GroupDependencyGraph validation rules</text>

  <text x="50"  y="448" fill="#AB47BC"  font-family="monospace" font-size="9" font-weight="bold">Ph 4</text>
  <text x="80"  y="448" fill="#B8D0E8"  font-family="monospace" font-size="9">matched_router.zig  symmetric_steiner.zig</text>

  <text x="50"  y="464" fill="#FB8C00"  font-family="monospace" font-size="9" font-weight="bold">Ph 5</text>
  <text x="80"  y="464" fill="#B8D0E8"  font-family="monospace" font-size="9">shield_router.zig  ShieldDB SoA</text>

  <text x="50"  y="480" fill="#EF5350"  font-family="monospace" font-size="9" font-weight="bold">Ph 6</text>
  <text x="80"  y="480" fill="#B8D0E8"  font-family="monospace" font-size="9">guard_ring.zig  GuardRingDB SoA  donut geometry</text>

  <text x="460" y="400" fill="#00C4E8"  font-family="monospace" font-size="9" font-weight="bold">Ph 7</text>
  <text x="490" y="400" fill="#B8D0E8"  font-family="monospace" font-size="9">thermal.zig  ThermalMap 2D grid  Gaussian hotspot</text>

  <text x="460" y="416" fill="#1E88E5"  font-family="monospace" font-size="9" font-weight="bold">Ph 8</text>
  <text x="490" y="416" fill="#B8D0E8"  font-family="monospace" font-size="9">lde.zig  LDEConstraintDB  computeLDECost</text>

  <text x="460" y="432" fill="#43A047"  font-family="monospace" font-size="9" font-weight="bold">Ph 9</text>
  <text x="490" y="432" fill="#B8D0E8"  font-family="monospace" font-size="9">pex_feedback.zig  MatchReportDB  pexFeedbackLoop</text>

  <text x="460" y="448" fill="#AB47BC"  font-family="monospace" font-size="9" font-weight="bold">Ph10</text>
  <text x="490" y="448" fill="#B8D0E8"  font-family="monospace" font-size="9">thread_pool.zig  WorkQueue  ThreadLocalState  colorGroups</text>

  <text x="460" y="464" fill="#FB8C00"  font-family="monospace" font-size="9" font-weight="bold">Ph11</text>
  <text x="490" y="464" fill="#B8D0E8"  font-family="monospace" font-size="9">analog_router.zig  lib.zig export  end-to-end tests</text>
</svg>
```

## Phase Reference Table

| Phase | Files | Entry points | Dependencies |
|-------|-------|-------------|--------------|
| 1 | `analog_types.zig`, `analog_db.zig`, `spatial_grid.zig`, `analog_tests.zig` | `AnalogSegmentDB.init`, `SpatialGrid.init` | `core/types.zig`, `core/route_arrays.zig` |
| 2 | `spatial_grid.zig` (extend) | `SpatialDrcChecker.checkSpacing` | Phase 1 |
| 3 | `analog_groups.zig` | `AnalogGroupDB.addGroup`, `GroupDependencyGraph.build` | Phase 1 |
| 4 | `matched_router.zig`, `symmetric_steiner.zig` | `MatchedRouter.routeGroup` | Phases 1–3 |
| 5 | `shield_router.zig` | `ShieldRouter.routeShielded`, `routeDrivenGuard` | Phases 1–4 |
| 6 | `guard_ring.zig` | `GuardRingInserter.insert`, `insertWithStitchIn`, `mergeDeepNWell` | Phases 1–3 |
| 7 | `thermal.zig` | `ThermalMap.addHotspot`, `computeThermalCost`, `extractIsotherm` | Phases 1–2 |
| 8 | `lde.zig` | `LDEConstraintDB.generateKeepouts`, `computeLDECost` | Phases 1–2 |
| 9 | `pex_feedback.zig` | `computeMatchReport`, `pexFeedbackLoop` | Phases 1–4 |
| 10 | `thread_pool.zig` | `ThreadPool.submitAndWait`, `colorGroups`, `mergeThreadLocalSegments` | Phases 1–9 |
| 11 | `analog_router.zig` | `AnalogRouter.route`, lib.zig export | Phases 1–10 |

---

## Phase 1 — Core Types + AnalogRouteDB

**Goal:** Establish all ID types, enums, geometry structs, and the master `AnalogSegmentDB` SoA table. Every later phase imports from these files without modification.

**New files:**
- `src/router/analog_types.zig` (~250 lines)
- `src/router/analog_db.zig` (~550 lines)
- `src/router/spatial_grid.zig` (skeleton)
- `src/router/analog_tests.zig` (~300 lines)

### ID Types

Five new opaque enum IDs added to `src/core/types.zig`:

| Type | Backing | Notes |
|------|---------|-------|
| `AnalogGroupIdx` | `u32` | Max 4B groups |
| `SegmentIdx` | `u32` | Indexes into `AnalogSegmentDB` |
| `ShieldIdx` | `u32` | Indexes into `ShieldDB` |
| `GuardRingIdx` | `u16` | Max 65535 guard rings |
| `ThermalCellIdx` | `u32` | Indexes into `ThermalMap` flat array |

All provide `toInt()`/`fromInt()` inline methods. Compile-time `@sizeOf` assertions enforce the backing sizes.

### analog_types.zig

**Enums:**

`AnalogGroupType` (`u8`): `differential` (2 nets, mirrored), `matched` (N nets, equal R/C/length/vias), `shielded` (1 signal + 1 shield net), `kelvin` (force + sense, 4-wire), `resistor_matched` (common centroid), `capacitor_array` (unit cap array).

`GroupStatus` (`u8`): `pending`, `routing`, `routed`, `failed`.

`RepairAction` (`u8`): `none`, `adjust_width` (R mismatch), `adjust_layer` (C mismatch), `add_jog` (length mismatch), `add_dummy_via` (via count mismatch), `rebalance_layer` (coupling mismatch).

`RoutingResult` (`u8`): `success`, `mismatch_exceeded`, `no_path`, `max_iterations`.

`SymmetryAxis` (`u8`): `x` (mirror across y), `y` (mirror across x).

**Geometry struct — `Rect`:**

```
Rect { x1, y1, x2, y2: f32 }
  .width()            → x2 - x1
  .height()           → y2 - y1
  .area()             → width × height
  .centerX/Y()        → midpoint
  .overlaps(other)    → AABB test
  .overlapsWithMargin(other, margin)
  .expand(amount)     → uniform outset on all sides
  .union_(other)      → bounding union
```

**Compile-time assertions** verify all ID and enum sizes.

### AnalogSegmentDB (analog_db.zig)

The central SoA table for analog wire segments, organized in hot/warm/cold column groups:

**Hot columns** (accessed every routing step): `x1`, `y1`, `x2`, `y2`, `width` (`[]f32`), `layer` (`[]u8`), `net` (`[]NetIdx`).

**Warm columns** (accessed during group assembly): `group` (`[]AnalogGroupIdx`), `segment_flags` (`[]SegmentFlags`).

**Cold columns** (accessed only during PEX): `resistance`, `capacitance`, `coupling_cap` (`[]f32`).

`SegmentFlags` is a `packed struct(u8)` with three boolean fields — `is_shield`, `is_dummy_via`, `is_jog` — and 5 padding bits.

`append(AppendParams)` grows by factor 2 when `len >= capacity`. `AppendParams` carries all geometry fields plus optional `flags` defaulting to `{}`. PEX columns initialise to 0.0 on append.

---

## Phase 2 — Spatial Grid

**Goal:** Replace the O(n) `InlineDrcChecker.checkSpacing` with an O(1) uniform grid query for DRC spacing checks during routing.

**Modified file:** `src/router/spatial_grid.zig` (extend Phase 1 skeleton).

### SpatialGrid

```
SpatialGrid {
    cells:     []std.ArrayListUnmanaged(u32),  // segment indices per cell
    width:     u32,   // grid columns
    height:    u32,   // grid rows
    cell_size: f32,   // µm per cell, = max(max_spacing × 2.0, 0.01)
    origin_x:  f32,
    origin_y:  f32,
    allocator: std.mem.Allocator,
}
```

**Cell size selection:** `@max(max_spacing * 2.0, 0.01)`. With SKY130 `min_spacing = 0.14 µm`, cell size = 0.28 µm. Each cell stores a list of segment indices (not segment data) so cells can be rebuilt cheaply.

**Grid is rebuilt between wavefronts** — not incrementally updated. Rebuild cost is O(n) over all existing segments.

**`NeighborIterator`** yields all cells in the 3×3 neighborhood around a query point. Handles boundary clamping. Used by `SpatialDrcChecker.checkSpacing` to limit the segment scan to at most 9 cells.

**`SpatialDrcChecker.checkSpacing(layer, x, y, net)`** returns `DrcResult`:
1. Map `(x, y)` to cell `(cx, cy)`.
2. Iterate 3×3 neighborhood via `NeighborIterator`.
3. For each segment index in neighborhood cells: skip same-net, check layer match, compute projection gap `max(gap_x, gap_y)` where gap is the signed distance between the query point and the segment bounding box.
4. Return `conflict` if `projection_gap < min_spacing[layer]`; otherwise `ok`.

**Projection gap formula** (from `DRC_RULES.md`): `gap = max(gap_x, gap_y)` where `gap_x = max(0, max(seg.x1, seg.x2) - x, x - min(seg.x1, seg.x2))` and similarly for y.

---

## Phase 3 — Analog Group Database

**Goal:** Implement `AnalogGroupDB` — the SoA table that stores group metadata — and `GroupDependencyGraph` — the conflict graph used by the thread pool for wavefront coloring.

**New file:** `src/router/analog_groups.zig`.

### AnalogGroupDB

SoA layout with six column groups:

**Identity (1 byte/group hot):** `group_type: []AnalogGroupType`, `status: []GroupStatus`.

**Connectivity (per group):** `net_ids: [][]NetIdx` (slice of slices), `num_nets: []u8`.

**Spatial (4 floats/group hot):** `bounding_rect: []Rect`.

**Matching parameters (cold):** `target_r_ratio`, `target_c_ratio` (`[]f32`), `tolerance: []f32`.

**`addGroup(AddGroupRequest)`** validates net count against group type, checks for duplicate net membership, assigns status `pending`, appends all columns atomically or returns `AddGroupError`.

**Validation rules:**
- `differential` requires exactly 2 nets.
- `matched` requires ≥ 2 nets.
- `shielded` requires exactly 2 nets (signal + shield).
- `kelvin` requires exactly 4 nets (force+, force−, sense+, sense−).
- `resistor_matched` / `capacitor_array` require ≥ 2 nets.
- No net may appear in two groups simultaneously.

**`netsForGroup(group_idx)`** returns the `net_ids[group_idx]` slice for use by `WorkItem`.

### GroupDependencyGraph

```
GroupDependencyGraph {
    adjacency:  []std.ArrayListUnmanaged(AnalogGroupIdx),
    num_groups: usize,
    allocator:  std.mem.Allocator,
}
```

Two groups are adjacent if they share a net, their bounding rects overlap, or one has a shield/guard-ring dependency on the other. The graph is built once before the thread pool is started. It is consumed by `colorGroups` in Phase 10.

---

## Phase 4 — Matched Router

**Goal:** Route differential and matched-impedance net groups using a mirrored A* topology with balanced wirelength and via count.

**New files:** `src/router/matched_router.zig`, `src/router/symmetric_steiner.zig`.

### SymmetricSteiner

`SymmetricSteiner` wraps the existing `SteinerTree` to produce mirrored topology for a differential pair:

1. Build a Steiner tree on the positive-net pin positions using the standard MST + Hanan heuristic.
2. Mirror every Steiner segment across the symmetry axis (centroid of all pins by default).
3. Emit the mirrored edges as the negative-net Steiner topology.

The symmetry axis is determined from `SymmetryAxis` (`.x` or `.y`) and the centroid of all pin positions.

### MatchedRouter

```
MatchedRouter {
    astar:      AStarRouter,
    steiner:    SymmetricSteiner,
    pdk:        *const PdkConfig,
    allocator:  std.mem.Allocator,
}
```

**`routeGroup(grid, net_p, net_n, pins_p, pins_n, axis)`:**
1. Build mirrored Steiner trees for both nets via `SymmetricSteiner`.
2. For each Steiner edge in the positive tree, route via A* on `grid`.
3. For the corresponding mirrored edge, route via A* with identical layer/direction hints.
4. Call `balanceWireLengths` and `balanceViaCounts` to equalise R and via count between the two routes.

**`balanceWireLengths(path_p, path_n, tolerance)`:** if `|len_p - len_n| / max(len_p, len_n) > tolerance`, insert a serpentine jog (set of horizontal detour segments) on the shorter path until the ratio falls within tolerance. Jog segments are tagged `is_jog = true` in `SegmentFlags`.

**`balanceViaCounts(path_p, path_n)`:** if `|via_p - via_n| > 0`, insert dummy vias (zero-length via segments tagged `is_dummy_via = true`) on the path with fewer vias.

**`MatchedRoutingCost`** augments the base A* cost:
- `r_mismatch_weight: f32 = 2.0` — penalty for deviation from target resistance ratio.
- `c_mismatch_weight: f32 = 1.5` — penalty for deviation from target capacitance ratio.
- `via_mismatch_weight: f32 = 3.0` — penalty for via count imbalance.
- These penalties are added to the base A* cost function during path search.

**`emitToSegmentDB(db, group, default_width)`** copies all routed segments from the internal `RoutePath` arrays into the provided `AnalogSegmentDB` with the correct `group` tag.

---

## Phase 5 — Shield Router

**Goal:** Route shielded signal nets surrounded by grounded shield wires at the correct DRC spacing.

**New file:** `src/router/shield_router.zig`.

### ShieldDB

SoA table for shield wire metadata:

| Column | Type | Description |
|--------|------|-------------|
| `signal_net` | `[]NetIdx` | Net being shielded |
| `shield_net` | `[]NetIdx` | GND net forming the shield |
| `layer` | `[]u8` | Routing layer |
| `clearance` | `[]f32` | Spacing from signal to shield edge |
| `x1/y1/x2/y2` | `[]f32` | Shield segment geometry |

### ShieldRouter Algorithms

**`routeShielded(signal_route, shield_net, pdk)`:** Given a routed signal path, generate parallel shield wires at distance `clearance = min_spacing[layer] + wire_width/2` on both sides of every signal segment. Shield segments follow the exact route topology of the signal wire.

**`routeDrivenGuard(signal_route, guard_net, pdk)`:** For segments where the signal wire changes layer via a via, extend the shield to wrap the via on the same layer below and above. Inserts short horizontal shield stubs at each via column.

**Geometry rules:**
- Shield wire width = `min_width[layer]` (0.14 µm on M1–M3).
- Clearance from signal wire edge to shield wire edge = `min_spacing[layer]`.
- Two shield wires (one per side) per signal segment.
- At corners (direction change), the shield segments meet at a 45° mitre or use a L-jog.
- Via wrapping: each via in the signal route gets a corresponding via in each shield wire if the shield is on the same layer above and below.

**Edge cases:** if a shield segment would violate DRC with a third-party segment, the shield is rerouted via A* with the signal wire marked as a friendly (same-group) obstacle.

---

## Phase 6 — Guard Ring Inserter

**Goal:** Insert substrate isolation guard rings around device groups, handle stitching at abutment, and merge deep N-well rings.

**New file:** `src/router/guard_ring.zig`.

### GuardRingDB

SoA table:

| Column | Type | Description |
|--------|------|-------------|
| `inner_x1/y1/x2/y2` | `[]f32` | Inner rect of the donut |
| `outer_x1/y1/x2/y2` | `[]f32` | Outer rect of the donut |
| `ring_type` | `[]GuardRingType` | `p_well`, `n_well`, `deep_n_well` |
| `net` | `[]NetIdx` | Connected net (GND or VDD) |
| `contact_pitch` | `[]f32` | Spacing between contact cuts |

### GuardRingType

`GuardRingType` enum (`u8`): `p_well`, `n_well`, `deep_n_well`.

### Guard Ring Geometry

A guard ring is a closed rectangular donut: four segments (top, bottom, left, right sides) on the ring layer, with contact cuts placed at `contact_pitch` intervals along all four sides. In SKY130: ring layer is `licon.drawing` + `li.drawing`; contact cuts are `licon.drawing` vias.

**Donut dimensions:** inner rect = device bounding box expanded by `guard_ring_spacing`; outer rect = inner rect expanded by `guard_ring_width`. Default PDK values: `guard_ring_width = 0.17 µm`, `guard_ring_spacing = 0.18 µm`.

**Contact placement:** distributed uniformly along all four sides at pitch. The first and last contacts are placed at `contact_pitch/2` from the ring corners to avoid corner DRC violations.

### Algorithms

**`insert(device_rect, ring_type, net, pdk)`:** Compute inner/outer rects, generate 4 ring segments, place contacts, append to `GuardRingDB`, return `GuardRingIdx`.

**`insertWithStitchIn(device_rect, ring_type, net, adjacent_ring_idx, pdk)`:** Like `insert` but omits the shared wall between this ring and `adjacent_ring_idx` and instead places a stitch metal segment connecting the two rings' wells. Used when two identically-typed rings are abutted.

**`clipToDieEdge(ring_idx, die_rect)`:** If any ring segment extends outside `die_rect`, clip it to the die boundary and remove the out-of-bounds contacts.

**`mergeDeepNWell(ring_indices)`:** Given a set of `deep_n_well` guard rings, compute their bounding union and generate a single outer deep N-well ring enclosing all of them, then remove the individual deep N-well segments from `GuardRingDB`.

---

## Phase 7 — Thermal Router

**Goal:** Build a 2D thermal map from device power dissipation and use it to steer routing away from hot spots.

**New file:** `src/router/thermal.zig`.

### ThermalMap

```
ThermalMap {
    cells:     []f32,   // flat 2D array, row-major
    width:     u32,
    height:    u32,
    cell_size: f32,     // µm, typically 10.0
    origin_x:  f32,
    origin_y:  f32,
    allocator: std.mem.Allocator,
}
```

Cell size is 10 µm — coarser than the routing grid — because thermal gradients in SKY130 are on the 10–100 µm scale.

**`addHotspot(x, y, power_mW, sigma_um)`:** Model a point heat source at `(x, y)` with power in milliwatts by adding a Gaussian kernel to all cells within `3 × sigma`:

```
T[cx][cy] += (power / (2π σ²)) × exp(-r² / (2σ²))
  where r = distance from (x, y) to cell centre
```

**`query(x, y)`:** Bilinear interpolation across the 4 nearest cells. Returns temperature in arbitrary units (proportional to °C rise from ambient).

**`extractIsotherm(threshold)`:** Returns a list of `Rect` regions where `T > threshold`. Implemented as a greedy scanline: scan cells row by row, merge adjacent hot cells in the same row, then merge adjacent rows with identical x-extents.

**`computeThermalCost(x, y, layer)`:** Returns an additive cost for routing through position `(x, y)` on `layer`. Metal layers closer to the substrate (lower layer numbers) have higher thermal coupling and a higher multiplier. Formula:

```
thermal_cost = query(x, y) × layer_factor[layer]
layer_factor = [1.0, 0.8, 0.6, 0.4, 0.3, 0.2]  // LI → M5
```

This cost is added to the A* `g` score during path expansion (via the `drc_weight` channel in `AStarRouter`).

---

## Phase 8 — LDE Router

**Goal:** Generate well-proximity-effect keepout zones around devices and penalise routes that violate device symmetry by exposing one device of a matched pair to asymmetric LDE stress.

**New file:** `src/router/lde.zig`.

### LDEConstraintDB

SoA table:

| Column | Type | Description |
|--------|------|-------------|
| `device` | `[]DeviceIdx` | Device with LDE constraint |
| `keepout` | `[]Rect` | Region that must not contain metal |
| `sa_rect` | `[]Rect` | Source-adjacency keepout (NMOS: left, PMOS: right) |
| `sb_rect` | `[]Rect` | Drain-adjacency keepout (NMOS: right, PMOS: left) |
| `constraint_type` | `[]LDEConstraintType` | `wpe_keepout`, `sa_sb_match` |

### Rect.expandAsymmetric

`Rect` gains `expandAsymmetric(left, right, top, bottom)` to generate asymmetric keepouts based on device SA/SB distances.

### generateKeepouts

`generateKeepouts(devices, pdk)` iterates all devices, computes their SA/SB distances, and appends `LDEConstraint` entries. For NMOS: SA side = source side (left by convention), SB side = drain side (right). For PMOS the convention is reversed. The keepout rect is expanded by `wpe_radius` (PDK-specific; SKY130 uses 3.0 µm) from the active area edge.

### computeLDECost

`computeLDECost(x, y, layer, constraints)` returns a penalty if the routing point `(x, y)` is inside any LDE keepout rect. The base penalty is proportional to the overlap depth (how far inside the keepout the point is).

`computeLDECostScaled(group, x, y, layer, constraints)` additionally penalises **asymmetry** within a matched group: if routing on one side of the group passes through a keepout but the mirrored position does not, the asymmetry penalty is double the base penalty. This forces matched pairs into symmetric routing even if both routes individually would be DRC-clean.

---

## Phase 9 — PEX Feedback Loop

**Goal:** After initial routing, extract parasitics from the route geometry, compare them against matching targets, and iteratively repair the routing until convergence or the iteration limit is reached.

**New file:** `src/router/pex_feedback.zig`.

### Data Structures

**`NetResult`:** per-net extraction result:
```
NetResult {
    net:         NetIdx,
    resistance:  f32,   // total Ω
    capacitance: f32,   // total fF
    coupling:    f32,   // total coupling fF to other nets
    length:      f32,   // total wirelength µm
    via_count:   u32,
}
```

**`MatchReport`:** per-group comparison:
```
MatchReport {
    group:          AnalogGroupIdx,
    r_ratio:        f32,   // R_net0 / R_net1
    c_ratio:        f32,   // C_net0 / C_net1
    length_ratio:   f32,
    via_delta:      i32,   // via_net0 - via_net1
    coupling_delta: f32,   // coupling difference
    action:         RepairAction,
    converged:      bool,
}
```

### MatchReportDB

SoA table with columns for all `MatchReport` fields, indexed by `AnalogGroupIdx`.

### Algorithms

**`extractNet(segments, net, pdk)`** → `NetResult`: iterates all segments with `net == net_id`, sums resistance (`ρ × length / (width × thickness)` per layer), capacitance (`ε × width × length / dielectric_thickness` per layer), and coupling (pairwise same-layer spacing check). Layer constants from `PdkConfig` (`metal_thickness`, `dielectric_thickness`).

**`computeMatchReport(group, segments, pdk, tolerance)`** → `MatchReport`: calls `extractNet` for both nets in the group, computes ratios, selects `RepairAction` from the following dispatch table:

| Condition | Action |
|-----------|--------|
| `|r_ratio - 1| > tolerance` | `adjust_width` |
| `|c_ratio - 1| > tolerance` | `adjust_layer` |
| `|length_ratio - 1| > tolerance` | `add_jog` |
| `|via_delta| > 0` | `add_dummy_via` |
| `|coupling_delta| > tolerance × coupling` | `rebalance_layer` |
| All within tolerance | `none` (converged) |

**`repairFromPexReport(group, report, segments, pdk)`:** applies the selected `RepairAction` by modifying segments in-place:
- `adjust_width`: scale segment widths by `1 / r_ratio`.
- `adjust_layer`: move segments to a layer with lower capacitance per unit length.
- `add_jog`: insert jog segments on the shorter net.
- `add_dummy_via`: insert zero-area via segments on the lower-via-count net.
- `rebalance_layer`: swap matched-pair segments to alternate layers.

**`pexFeedbackLoop(groups, segments, pdk, max_iter=5)`** → `RoutingResult`:
```
for iter in 0..max_iter:
    for each group:
        report = computeMatchReport(group, segments, pdk, tolerance)
        if report.converged: continue
        repairFromPexReport(group, report, segments, pdk)
    if all groups converged: return .success
return .max_iterations
```

Returns `success` if all groups converge before `max_iter`, `max_iterations` otherwise.

---

## Phase 10 — Thread Pool + Parallel Dispatch

**Goal:** Parallelise group routing across CPU cores using a lock-free SPMC work queue and wavefront coloring.

**New file:** `src/router/thread_pool.zig`.

For the full threading model specification — including `WorkQueue`, `ThreadPool`, `ThreadLocalState`, `colorGroups`, segment merge, synchronisation points, and data race analysis — see the [Threading Model](threading.md) reference.

### Key types added in this phase

| Type | Role |
|------|------|
| `WorkItem` | Unit of work: one group, routes via `execute()` or `executeWithRouter()` |
| `WorkQueue` | SPMC bounded queue; `push` (main), `pop` (workers, CAS) |
| `ThreadPool` | Owns worker threads + queue; `submitAndWait`, `submitWavefronts` |
| `ThreadLocalState` | Per-thread arena + `AnalogSegmentDB`; reset between wavefronts |
| `ColorResult` | Output of `colorGroups`: `colors[]u8` + `num_colors` |
| `RouteJob` | Scheduling descriptor with `priority` field |
| `RouteResult` | Per-group statistics: `segment_count`, `via_count`, `total_length`, `success` |
| `SegmentConflict` | Post-route spacing violation record |

### selectThreadCount

`selectThreadCount(num_groups)` reads `std.Thread.getCpuCount()` (fallback 4), returns `min(num_groups, hw_threads, 16)` clamped to at least 1.

---

## Phase 11 — Integration + Signoff

**Goal:** Assemble all phases behind a single public API, wire the analog pass before the digital detailed router, export symbols from `lib.zig`, and verify with end-to-end circuit tests.

**New file:** `src/router/analog_router.zig`.
**Modified files:** `src/router/detailed.zig`, `src/lib.zig`.

### AnalogRouter

```
AnalogRouter {
    matched_router:   MatchedRouter,
    shield_router:    ShieldRouter,
    guard_ring:       GuardRingInserter,
    thermal_map:      ThermalMap,
    lde_db:           LDEConstraintDB,
    thread_pool:      ThreadPool,
    group_db:         AnalogGroupDB,
    segment_db:       AnalogSegmentDB,
    pdk:              *const PdkConfig,
    allocator:        std.mem.Allocator,
}
```

**`route(devices, nets, pins, adj, pdk)`** → `AnalogRoutingResult`:

1. `generateKeepouts(devices, pdk)` → `LDEConstraintDB`.
2. `addHotspot` for each device from power map → `ThermalMap`.
3. Build `GroupDependencyGraph` from `AnalogGroupDB`.
4. `colorGroups(graph)` → `ColorResult`.
5. Rebuild `SpatialGrid` from existing segments.
6. `thread_pool.submitWavefronts(groups, colors, thread_locals, segment_db, routes)`.
7. `pexFeedbackLoop(groups, segment_db, pdk, max_iter=5)`.
8. `insertGuardRings(devices, pdk)`.
9. `routeShieldedGroups(groups, segment_db, pdk)`.
10. `mergeThreadLocalToRouteArrays(routes, thread_locals)`.

### AnalogRoutingResult

```
AnalogRoutingResult {
    routes:             RouteArrays,
    match_reports:      MatchReportDB,
    guard_rings:        GuardRingDB,
    thermal_map:        ThermalMap,
    num_groups_routed:  u32,
    num_groups_failed:  u32,
    pex_iterations:     u32,
    result:             RoutingResult,
}
```

### Integration with detailed.zig

`DetailedRouter.routeAll` is modified to call `AnalogRouter.route` first for all groups registered in `AnalogGroupDB`, consuming the resulting `RouteArrays` as pre-placed obstacles before the digital A* pass begins. Nets that were routed by the analog pass are skipped in the digital ordering loop.

### lib.zig exports

```zig
pub const AnalogRouter = @import("router/analog_router.zig").AnalogRouter;
pub const AnalogGroupDB = @import("router/analog_groups.zig").AnalogGroupDB;
pub const MatchReport = @import("router/pex_feedback.zig").MatchReport;
pub const GuardRingInserter = @import("router/guard_ring.zig").GuardRingInserter;
pub const ThermalMap = @import("router/thermal.zig").ThermalMap;
```

### End-to-End Test Circuits

Three circuits verify Phase 11 integration:

**1. Differential pair (2-transistor):**
Two NMOS transistors, nets: `vp`, `vn`, `vdd`, `gnd`. Expected: symmetric route with wirelength ratio ≤ 1.01, zero LVS shorts, guard ring inserted.

**2. Current mirror (matched pair):**
NMOS reference + NMOS copy. Expected: matched total resistance within 1%, capacitance within 2%, via counts equal.

**3. OTA input stage (4-transistor):**
Differential input PMOS pair + NMOS tail current mirror. Expected: ≤ 5 PEX iterations to converge, all matched groups `routed`, no DRC violations from `detectSegmentConflicts`.

---

## Conventions and Invariants (Cross-Phase)

All phases must respect the following invariants established in Phase 1:

**Layer index convention:**
```
Route layer: 0=LI, 1=M1, 2=M2, 3=M3, 4=M4, 5=M5
PDK index:   pdk_idx = route_layer - 1   (for route_layer >= 1)
Grid layer:  grid_layer = route_layer - 1
```

**DOD rules:**
1. SoA via separate slices — not `MultiArrayList`.
2. Opaque enum IDs for all table keys — compile-time type safety, zero runtime cost.
3. Hot/cold field split — hot fields in the first cache lines of each SoA.
4. Existence tables — membership = boolean condition, no `is_X: bool` in hot loops.
5. Arena allocation — per-pass scratch memory, reset not free.
6. Flat arrays indexed by ID — no `HashMap` for dense sequential keys.

**Error handling:** all allocating functions return `!T`. Recoverable routing failures (no A* path, DRC conflict during shield placement) set `GroupStatus.failed` and return without propagating an error. Only OOM and invariant violations propagate.

**SKY130 PDK values:**
```
num_metal_layers = 5
min_spacing[M1..M3] = 0.14 µm,  min_spacing[M4..M5] = 0.28 µm
min_width[M1..M3]   = 0.14 µm,  min_width[M4..M5]   = 0.30 µm
guard_ring_width    = 0.17 µm
guard_ring_spacing  = 0.18 µm
db_unit             = 0.001 µm  (1 nm grid)
```
