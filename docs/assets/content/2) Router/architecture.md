# Spout Router — Full Architecture

## Overview

Spout implements a hybrid routing architecture that combines a standard A*-based global and detailed router with a bespoke analog post-processing engine. The router targets the SKY130 PDK and is written entirely in Zig 0.15 using data-oriented design (DOD) principles throughout.

The fundamental design goal is:

> Zero DRC violations. LVS-correct netlist. PEX-optimized layout. Matched parasitics for analog circuits.

This document covers the complete pipeline, all data structures, cost functions, threading model, and how routes are stored.

---

## Pipeline Overview

```svg
<svg viewBox="0 0 900 620" xmlns="http://www.w3.org/2000/svg" font-family="'Inter', 'Segoe UI', sans-serif">
  <title>Spout Router Pipeline</title>
  <rect width="900" height="620" fill="#060C18"/>

  <!-- Title -->
  <text x="18" y="28" fill="#3E5E80" font-size="11" font-style="italic">Spout Router — Full Pipeline</text>

  <!-- Stage boxes -->
  <!-- Stage 1: Net ordering -->
  <rect x="60" y="60" width="200" height="64" rx="6" fill="#09111F" stroke="#14263E" stroke-width="1.5"/>
  <text x="160" y="86" text-anchor="middle" fill="#00C4E8" font-size="13" font-weight="600">Net Ordering</text>
  <text x="160" y="103" text-anchor="middle" fill="#B8D0E8" font-size="10">Power → HPWL asc → fanout asc</text>
  <text x="160" y="116" text-anchor="middle" fill="#3E5E80" font-size="9">detailed.zig : NetOrder sort</text>

  <!-- Stage 2: Steiner Tree -->
  <rect x="60" y="165" width="200" height="64" rx="6" fill="#09111F" stroke="#14263E" stroke-width="1.5"/>
  <text x="160" y="191" text-anchor="middle" fill="#00C4E8" font-size="13" font-weight="600">Steiner Tree Topology</text>
  <text x="160" y="208" text-anchor="middle" fill="#B8D0E8" font-size="10">Hanan-grid MST / 1-Steiner</text>
  <text x="160" y="221" text-anchor="middle" fill="#3E5E80" font-size="9">steiner.zig : SteinerTree.build()</text>

  <!-- Stage 3: A* routing -->
  <rect x="60" y="270" width="200" height="64" rx="6" fill="#09111F" stroke="#14263E" stroke-width="1.5"/>
  <text x="160" y="296" text-anchor="middle" fill="#00C4E8" font-size="13" font-weight="600">A* Multi-Layer Route</text>
  <text x="160" y="313" text-anchor="middle" fill="#B8D0E8" font-size="10">GCell grid · DRC filter · congestion</text>
  <text x="160" y="326" text-anchor="middle" fill="#3E5E80" font-size="9">astar.zig : AStarRouter.findPath()</text>

  <!-- Stage 4: Inline DRC -->
  <rect x="60" y="375" width="200" height="64" rx="6" fill="#09111F" stroke="#14263E" stroke-width="1.5"/>
  <text x="160" y="401" text-anchor="middle" fill="#00C4E8" font-size="13" font-weight="600">Inline DRC Filter</text>
  <text x="160" y="418" text-anchor="middle" fill="#B8D0E8" font-size="10">spacing · width · via enclosure</text>
  <text x="160" y="431" text-anchor="middle" fill="#3E5E80" font-size="9">inline_drc.zig : InlineDrcChecker</text>

  <!-- Stage 5: Route storage -->
  <rect x="60" y="480" width="200" height="64" rx="6" fill="#09111F" stroke="#14263E" stroke-width="1.5"/>
  <text x="160" y="506" text-anchor="middle" fill="#00C4E8" font-size="13" font-weight="600">RouteArrays Storage</text>
  <text x="160" y="523" text-anchor="middle" fill="#B8D0E8" font-size="10">SoA segments committed</text>
  <text x="160" y="536" text-anchor="middle" fill="#3E5E80" font-size="9">core/route_arrays.zig</text>

  <!-- Arrows digital path -->
  <line x1="160" y1="124" x2="160" y2="165" stroke="#00C4E8" stroke-width="1.5" marker-end="url(#arr)"/>
  <line x1="160" y1="229" x2="160" y2="270" stroke="#00C4E8" stroke-width="1.5" marker-end="url(#arr)"/>
  <line x1="160" y1="334" x2="160" y2="375" stroke="#00C4E8" stroke-width="1.5" marker-end="url(#arr)"/>
  <line x1="160" y1="439" x2="160" y2="480" stroke="#00C4E8" stroke-width="1.5" marker-end="url(#arr)"/>

  <!-- Analog section (right side) -->
  <text x="560" y="28" text-anchor="middle" fill="#3E5E80" font-size="11" font-style="italic">Analog Post-Processing</text>

  <!-- Analog: Matched router -->
  <rect x="450" y="60" width="220" height="64" rx="6" fill="#09111F" stroke="#1E88E5" stroke-width="1.5"/>
  <text x="560" y="86" text-anchor="middle" fill="#1E88E5" font-size="13" font-weight="600">Matched Router</text>
  <text x="560" y="103" text-anchor="middle" fill="#B8D0E8" font-size="10">Symmetric Steiner · wire-len balance</text>
  <text x="560" y="116" text-anchor="middle" fill="#3E5E80" font-size="9">matched_router.zig · symmetric_steiner.zig</text>

  <!-- Analog: Shield router -->
  <rect x="450" y="165" width="220" height="64" rx="6" fill="#09111F" stroke="#1E88E5" stroke-width="1.5"/>
  <text x="560" y="191" text-anchor="middle" fill="#1E88E5" font-size="13" font-weight="600">Shield Router</text>
  <text x="560" y="208" text-anchor="middle" fill="#B8D0E8" font-size="10">Adjacent-layer shield wires</text>
  <text x="560" y="221" text-anchor="middle" fill="#3E5E80" font-size="9">shield_router.zig</text>

  <!-- Analog: Guard rings -->
  <rect x="450" y="270" width="220" height="64" rx="6" fill="#09111F" stroke="#1E88E5" stroke-width="1.5"/>
  <text x="560" y="296" text-anchor="middle" fill="#1E88E5" font-size="13" font-weight="600">Guard Ring Inserter</text>
  <text x="560" y="313" text-anchor="middle" fill="#B8D0E8" font-size="10">P+/N+/deep-N-well rings</text>
  <text x="560" y="326" text-anchor="middle" fill="#3E5E80" font-size="9">guard_ring.zig</text>

  <!-- Analog: PEX feedback -->
  <rect x="450" y="375" width="220" height="64" rx="6" fill="#09111F" stroke="#43A047" stroke-width="1.5"/>
  <text x="560" y="401" text-anchor="middle" fill="#43A047" font-size="13" font-weight="600">PEX Feedback Loop</text>
  <text x="560" y="418" text-anchor="middle" fill="#B8D0E8" font-size="10">Extract → report → repair (×5 max)</text>
  <text x="560" y="431" text-anchor="middle" fill="#3E5E80" font-size="9">pex_feedback.zig</text>

  <!-- Analog: Parallel dispatch -->
  <rect x="450" y="480" width="220" height="64" rx="6" fill="#09111F" stroke="#FB8C00" stroke-width="1.5"/>
  <text x="560" y="506" text-anchor="middle" fill="#FB8C00" font-size="13" font-weight="600">Parallel Dispatch</text>
  <text x="560" y="523" text-anchor="middle" fill="#B8D0E8" font-size="10">Graph coloring · wavefronts · merge</text>
  <text x="560" y="536" text-anchor="middle" fill="#3E5E80" font-size="9">thread_pool.zig · parallel_router.zig</text>

  <!-- Arrows analog path -->
  <line x1="560" y1="124" x2="560" y2="165" stroke="#1E88E5" stroke-width="1.5" marker-end="url(#arr2)"/>
  <line x1="560" y1="229" x2="560" y2="270" stroke="#1E88E5" stroke-width="1.5" marker-end="url(#arr2)"/>
  <line x1="560" y1="334" x2="560" y2="375" stroke="#43A047" stroke-width="1.5" marker-end="url(#arr3)"/>
  <line x1="560" y1="439" x2="560" y2="480" stroke="#FB8C00" stroke-width="1.5" marker-end="url(#arr4)"/>

  <!-- Merge arrow: analog feeds into digital route storage -->
  <line x1="450" y1="512" x2="310" y2="512" stroke="#43A047" stroke-width="1.5" stroke-dasharray="6,3" marker-end="url(#arr3)"/>
  <text x="380" y="500" text-anchor="middle" fill="#43A047" font-size="9">merge</text>

  <!-- Connection between digital A* and analog matched router -->
  <line x1="260" y1="302" x2="450" y2="302" stroke="#3E5E80" stroke-width="1" stroke-dasharray="4,4"/>
  <text x="355" y="295" text-anchor="middle" fill="#3E5E80" font-size="9">shared grid</text>

  <!-- Defs for arrowheads -->
  <defs>
    <marker id="arr" markerWidth="8" markerHeight="8" refX="6" refY="3" orient="auto">
      <path d="M0,0 L0,6 L8,3 z" fill="#00C4E8"/>
    </marker>
    <marker id="arr2" markerWidth="8" markerHeight="8" refX="6" refY="3" orient="auto">
      <path d="M0,0 L0,6 L8,3 z" fill="#1E88E5"/>
    </marker>
    <marker id="arr3" markerWidth="8" markerHeight="8" refX="6" refY="3" orient="auto">
      <path d="M0,0 L0,6 L8,3 z" fill="#43A047"/>
    </marker>
    <marker id="arr4" markerWidth="8" markerHeight="8" refX="6" refY="3" orient="auto">
      <path d="M0,0 L0,6 L8,3 z" fill="#FB8C00"/>
    </marker>
  </defs>

  <!-- Section labels -->
  <text x="160" y="48" text-anchor="middle" fill="#B8D0E8" font-size="12" font-weight="600">Digital Route Path</text>
  <text x="560" y="48" text-anchor="middle" fill="#B8D0E8" font-size="12" font-weight="600">Analog Route Path</text>

  <!-- Vertical divider -->
  <line x1="420" y1="40" x2="420" y2="590" stroke="#14263E" stroke-width="1" stroke-dasharray="8,4"/>
</svg>
```

---

## Stage 1 — Net Ordering (`detailed.zig`)

Before any routing begins, all nets are sorted according to a three-key priority:

1. **Power nets first** — `VDD`, `VSS`, and power domain rails are routed before signal nets so that their low-impedance paths are established and act as routing obstacles for later nets.
2. **Ascending HPWL** (half-perimeter wire length) — shorter nets are easier to route and are less likely to conflict with later, longer nets. Routing short nets first minimises congestion build-up.
3. **High-fanout last** — nets with many pins (high fanout) constrain more grid cells; routing them last lets the router see the full congestion picture.

The ordering key is `NetOrder = { net_idx, is_power: bool, hpwl: f32, fanout: u16 }`, sorted by `netOrderLessThan`.

**Layer index convention** used throughout:

| Route Layer Index | Metal |
|---|---|
| 0 | LI (local interconnect) |
| 1 | M1 |
| 2 | M2 |
| 3 | M3 |
| 4 | M4 |
| 5 | M5 |

PDK arrays (`min_spacing`, `min_width`, etc.) are 0-indexed from M1, so `pdk.min_width[route_layer - 1]` for metal layers. This mapping is encoded in `pdkIndex(route_layer: u8) usize { return route_layer - 1; }`.

---

## Stage 2 — Steiner Tree Decomposition (`steiner.zig`)

Multi-pin nets are decomposed into a minimum Steiner tree before routing. The implementation uses a Prim's-MST approach on a 256-point static buffer with the following special cases:

- **0 or 1 pins**: empty tree (nothing to route)
- **2 pins**: direct L-shape segment
- **3 pins**: median T-shape
- **N>3 pins**: 1-Steiner heuristic on the Hanan grid (grid of all pin x/y coordinates)

The tree produces a list of `Segment = { x1, y1, x2, y2 }` pairs. Each segment is then routed independently by the A* engine using the source and destination as grid-snapped nodes.

For analog groups, a **SymmetricSteiner** variant is used (`symmetric_steiner.zig`): the reference net's Steiner tree is computed first, then mirrored around the group's centroid axis to produce a topologically identical tree for the paired net.

---

## Stage 3 — A* Multi-Layer Routing (`astar.zig`)

### MultiLayerGrid (`grid.zig`)

The routing grid is a `MultiLayerGrid` — a 3D structure with one 2D track grid per metal layer. Each layer has:

- **`pitch`** — preferred-direction track pitch (µm)
- **`cross_pitch`** — non-preferred-direction cross pitch
- **`num_tracks`** — number of tracks in the preferred direction
- **`preferred direction`** — horizontal (H) or vertical (V) from `PdkConfig.metal_direction`
- **Per-cell data** — `congestion: u8`, `blocked: bool`, `reserved_net: NetIdx`

`GridNode = { layer: u8, track_a: u32, track_b: u32 }` addresses a point in the 3D grid. `track_a` indexes the preferred direction; `track_b` indexes the cross direction.

Node packing uses a `u64` key: `layer << 48 | track_a << 24 | track_b`, enabling O(1) hash operations in the open/closed/came-from maps.

### Cost Function

The total A* cost `f(n) = g(n) + h(n)` is composed as follows:

**Movement cost `g(n)`** — accumulated from source:

| Move type | Cost |
|---|---|
| Preferred direction (±1 track_a) | `pitch` µm |
| Cross direction (±1 track_b) | `cross_pitch * wrong_way_cost` (default 3.0×) |
| Via transition (layer ±1) | `via_cost * max(1.0, upper_pitch / lower_pitch)` (default via_cost = 3.0) |
| Via with track offset (±1 for grid quantization) | `base_via_cost + lower_pitch * 0.5` |
| Congestion penalty | `congestion_weight * cell.congestion` (default weight 0.5) |
| DRC soft penalty | `drc_weight * result.soft_penalty` (default weight 1.0) |

**Heuristic `h(n)`** — admissible lower bound:

```
h(n) = |world_x(n) - world_x(target)|
     + |world_y(n) - world_y(target)|
     + |layer(n) - layer(target)| * via_cost
```

This is a world-coordinate Manhattan distance plus a layer-change penalty. It is admissible because actual movement cost is always at least one pitch per track step, and the pitch cannot be less than the world distance divided by the number of steps.

**Near-target acceptance**: The A* search accepts a node as the goal if it is on the target layer and within 1 track in both dimensions of the target (`isNearTarget`). This handles grid quantization artifacts where a via lands slightly off-center.

### Neighbor Expansion

Each node expands up to 14 neighbors (stored in a fixed `NeighborBuf`):

1. `±1 track_a` (preferred direction) — 2 neighbors
2. `±1 track_b` (cross direction) — 2 neighbors
3. Via down (layer - 1): center + 8 offset combinations (3×3 minus already added) — up to 9 neighbors
4. Via up (layer + 1): center only — 1 neighbor

Via offsets account for the fact that different metal layers may have different pitches, so a node on layer L maps to a different grid position on layer L±1. The 3×3 neighborhood search around the projected via landing finds a reachable track.

### Inline DRC Filter (`inline_drc.zig`)

During expansion, each candidate neighbor is checked by `drcFilter()`:

```
drcFilter(nbr) ->
  world_pos = grid.nodeToWorld(nbr)
  result = drc_checker.checkSpacing(nbr.layer, world_pos[0], world_pos[1], net)
  if result.hard_violation: skip neighbor
  else: step_cost += drc_weight * result.soft_penalty
```

`InlineDrcChecker.checkSpacing` performs an O(n) linear scan over all committed `WireRect` segments on the same layer, computing the projection gap between each existing segment and the candidate point. If the gap is less than `min_spacing` and the nets differ, it returns a hard violation. Segments of the same net are skipped.

The `WireRect` structure stores actual micrometer geometry (not grid units), so spacing is computed in the physical domain.

### Path Reconstruction

After the goal is reached, the path is reconstructed by tracing the `cameFrom` map from target back to source, building the `nodes: []GridNode` array. The source is always `nodes[0]`; the target is always `nodes[len-1]`.

---

## Stage 4 — Inline DRC Architecture

The inline DRC checker (`inline_drc.zig`) enforces the following rules during routing. Rules not yet embedded (open gaps) are noted.

### Implemented

| Rule | Geometry | Cost |
|---|---|---|
| Metal-to-metal spacing (diff net) | `proj_gap(A,B) < min_spacing` | O(n) per expansion |
| Same-net spacing / notch | `proj_gap(same net) < same_net_spacing` | O(n) |
| Minimum wire width | `w < min_width[layer]` | O(1) |

### SKY130 Spacing Values (`pdks/sky130.json`)

| Layer | min_spacing | same_net_spacing | min_width |
|---|---|---|---|
| M1 | 0.14 µm | 0.14 µm | 0.14 µm |
| M2 | 0.14 µm | 0.14 µm | 0.14 µm |
| M3 | 0.14 µm | 0.14 µm | 0.14 µm |
| M4 | 0.28 µm | 0.28 µm | 0.30 µm |
| M5 | 0.28 µm | 0.28 µm | 0.30 µm |
| LI | 0.17 µm | — | 0.17 µm |

**Projection gap formula** (Manhattan, same as Magic and OpenROAD's FlexGC):

```
gap_x = max(ax0 − bx1,  bx0 − ax1)
gap_y = max(ay0 − by1,  by0 − ay1)
proj_gap = max(gap_x, gap_y)
```

`proj_gap < 0` → overlap (short); `= 0` → touching; `> 0` → legal separation.

### Open Gaps (Not Yet Implemented)

1. EOL (end-of-line) spacing — pin stubs are short enough to be EOL but are not currently checked
2. PRL (parallel run length) spacing — no parallel overlap detection
3. Wide metal spacing — no width-dependent spacing
4. Via enclosure in inline DRC — only caught in post-layout DRC
5. Density tracking — no sliding window density
6. Antenna ratio tracking — no per-net metal area accumulator

---

## Stage 5 — Route Storage (`route_arrays.zig`)

All committed route segments are stored in the `RouteArrays` structure, which is a Structure-of-Arrays (SoA) for maximum cache efficiency:

```
RouteArrays {
  layer:  []u8           -- route layer index (0=LI, 1=M1, ..., 5=M5)
  x1:     []f32          -- segment start X (µm)
  y1:     []f32          -- segment start Y (µm)
  x2:     []f32          -- segment end X (µm)
  y2:     []f32          -- segment end Y (µm)
  width:  []f32          -- wire width (µm)
  net:    []NetIdx       -- owning net (opaque u32 enum)
  flags:  []RouteSegmentFlags  -- packed: is_shield, is_dummy_via, is_jog
  len:    u32
  capacity: u32
}
```

`RouteSegmentFlags` is a `packed struct(u8)` with three boolean fields, occupying exactly 1 byte per segment. This keeps the hot geometry columns (layer, x1/y1/x2/y2, width, net) together for DRC/LVS/PEX operations that never read the flags.

The GDSII exporter maps route layer indices to PDK-specific layer/datatype pairs: `layer 0 → pdk.layers.li`, `layer 1 → pdk.layers.metal[0]`, etc.

### AnalogSegmentDB

The analog router uses `AnalogSegmentDB` (defined in `analog_db.zig`), which extends `RouteArrays` with analog-specific columns:

| Column group | Fields | Description |
|---|---|---|
| Geometry (hot) | x1, y1, x2, y2, width, layer, net | Identical to RouteArrays |
| Analog metadata (warm) | group: AnalogGroupIdx, segment_flags | Which group produced this segment |
| PEX cache (cold) | resistance, capacitance, coupling_cap | Extracted parasitic values (populated post-extraction) |

The `toRouteArrays()` method copies geometry columns to `RouteArrays` via `@memcpy`, enabling zero-copy integration with downstream tools.

---

## Analog Post-Processing Pipeline

After digital routes are committed, the analog post-processor runs on nets that belong to `AnalogGroupDB` entries.

### AnalogRouteDB — Master Database

`AnalogRouteDB` (in `analog_db.zig`) owns all analog routing state:

```
AnalogRouteDB {
  groups:       AnalogGroupDB      -- SoA table of net groups (Phase 3)
  segments:     AnalogSegmentDB    -- SoA table of routed segments (Phase 1)
  spatial:      SpatialGrid        -- Uniform 2D grid for O(1) DRC queries (Phase 2)
  shields:      ShieldDB           -- Shield wire records (Phase 5)
  guard_rings:  GuardRingDB        -- Guard ring geometry (Phase 6)
  thermal:      ?ThermalMap        -- Optional thermal map (Phase 7)
  lde:          LDEConstraintDB    -- SA/SB keepout constraints (Phase 8)
  match_reports: MatchReportDB     -- Per-group PEX match results (Phase 9)
  pass_arena:   ArenaAllocator     -- Scratch memory, reset between passes
  thread_arenas: []ArenaAllocator  -- Per-thread scratch arenas
}
```

All tables use SoA layout with opaque `enum(u32)` index types for compile-time type safety. Mixing a `SegmentIdx` with a `NetIdx` is a compile error.

### SpatialGrid — O(1) Neighborhood Queries

`SpatialGrid` (in `spatial_grid.zig`) replaces the O(n) linear scan in `InlineDrcChecker`:

- **Cell size** = `2 * max(min_spacing)` across all layers (typically `2 * 0.28 = 0.56 µm`)
- **Cell lookup**: `O(1)` via `cellIndex(x, y) = row * cells_x + col`
- **Neighborhood query**: 3×3 = 9 cells around the query point (covering any segment within `min_spacing`)
- **Cache behavior**: 9 cells × 6 bytes/cell metadata = 54 bytes → fits in 1 cache line
- **Thread safety**: read-only during routing; rebuilt between wavefronts (O(n))

Why uniform grid over R-tree: cell count is known at init from die bbox + pitch; routing segment density is roughly uniform; O(1) lookup vs O(log n); no tree rebalancing; bulk rebuild after rip-up is O(n) in both cases.

---

## DRC Rule Taxonomy

The full DRC rule set is documented in `DRC_RULES.md`. For routing purposes, the key rules are:

| Rule | Router action | Data structure |
|---|---|---|
| min_spacing | Block expansion if `proj_gap < threshold` | WireRect list, SpatialGrid |
| min_width | Block expansion if wire width < threshold | `min_width[layer]` from PdkConfig |
| via enclosure | Check `enc_rules` on via commit | `enc_rules` table, outer shapes |
| via-to-via spacing | Check on cut layer | Via WireRects |
| antenna ratio | Track metal area per net (planned) | Per-net area accumulator |
| density | Track per-grid-cell density (planned) | Grid-based density accumulator |

---

## File Map

| File | Role |
|---|---|
| `src/router/astar.zig` | A* search engine on MultiLayerGrid |
| `src/router/maze.zig` | Channel-based maze router (M1 trunk + M2 jog topology) |
| `src/router/detailed.zig` | DetailedRouter: net ordering, Steiner decomp, A* dispatch |
| `src/router/analog_router.zig` | AnalogRouter: Phase 11 integration orchestrator |
| `src/router/analog_types.zig` | ID types, enums, geometry structs |
| `src/router/analog_db.zig` | AnalogRouteDB master database |
| `src/router/analog_groups.zig` | AnalogGroupDB SoA table |
| `src/router/spatial_grid.zig` | Uniform 2D spatial grid |
| `src/router/matched_router.zig` | Symmetric Steiner + wire-length balancing |
| `src/router/symmetric_steiner.zig` | Mirror-image Steiner tree generation |
| `src/router/shield_router.zig` | Adjacent-layer shield wire placement |
| `src/router/guard_ring.zig` | Guard ring geometry + contact generation |
| `src/router/thermal.zig` | Thermal map + isotherm extraction |
| `src/router/lde.zig` | SA/SB keepout zones + LDE cost function |
| `src/router/pex_feedback.zig` | PEX feedback loop + repair dispatch |
| `src/router/parallel_router.zig` | Group dependency graph + wavefront coloring |
| `src/router/thread_pool.zig` | Lock-free SPMC work queue + ThreadPool |
| `src/router/inline_drc.zig` | Per-expansion DRC checker |
| `src/router/grid.zig` | MultiLayerGrid: 3D routing grid |
| `src/router/steiner.zig` | Prim's MST Steiner tree |
| `src/router/pin_access.zig` | Pin access point computation |
| `src/core/route_arrays.zig` | SoA segment storage (canonical output) |
| `src/core/device_arrays.zig` | Device geometry (positions, dimensions) |
| `src/router/analog_tests.zig` | All analog router tests (Phases 1–11) |
