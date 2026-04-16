# A* Global Router — Deep Dive

## Overview

The A* router (`src/router/astar.zig`) performs shortest-path routing on a multi-layer 3D grid. It is the core routing engine used by both the `DetailedRouter` (digital nets) and the `MatchedRouter` (analog groups). It is implemented from scratch in Zig 0.15 with no external routing library dependencies.

---

## GCell Grid Construction (`grid.zig`)

The `MultiLayerGrid` is built from device geometry and PDK parameters. Each layer has its own 2D grid of tracks.

### Initialization

```
MultiLayerGrid.init(allocator, device_arrays, pdk, die_size, optional_blockage)
```

For each metal layer `L` (0 = M1, 1 = M2, ...):

1. **Preferred direction** is read from `pdk.metal_direction[L]` (`.horizontal` or `.vertical`)
2. **Track pitch** = `pdk.metal_pitch[L]` µm
3. **Number of tracks** = `ceil(die_extent_along_preferred_axis / pitch)`
4. **Cross layer** tracks = `ceil(die_extent_along_cross_axis / cross_pitch)`
5. Device bounding boxes are marked as blocked cells

### GridNode

```zig
GridNode = {
  layer:   u8    -- metal layer index (0 = M1)
  track_a: u32   -- preferred-direction track index
  track_b: u32   -- cross-direction track index
}
```

World-coordinate conversions:
- `nodeToWorld(node) -> [2]f32`: `x = origin_x + track_a * pitch`, `y = origin_y + track_b * cross_pitch` (or transposed for vertical layers)
- `worldToNode(layer, x, y) -> GridNode`: inverse, snapped to nearest track

### NodeKey Packing

For hashing into `AutoHashMap`, nodes are packed into a `u64`:

```
NodeKey = layer << 48 | track_a << 24 | track_b
```

This enables O(1) hashmap operations. The packing assumes `layer < 256`, `track_a < 16M`, `track_b < 16M` — all satisfied for die sizes up to several millimetres at SKY130 pitch.

---

## GCell Grid Visualization

```svg
<svg viewBox="0 0 820 580" xmlns="http://www.w3.org/2000/svg" font-family="'Inter', 'Segoe UI', sans-serif">
  <title>A* GCell Grid Example</title>
  <rect width="820" height="580" fill="#060C18"/>
  <text x="14" y="24" fill="#3E5E80" font-size="11" font-style="italic">A* GCell Grid — 8×8 example with routed path</text>

  <!-- Grid definition: 8x8 cells, each 60px, starting at x=80,y=60 -->
  <!-- Row/col labels -->
  <text x="65" y="95" text-anchor="end" fill="#3E5E80" font-size="10">7</text>
  <text x="65" y="155" text-anchor="end" fill="#3E5E80" font-size="10">6</text>
  <text x="65" y="215" text-anchor="end" fill="#3E5E80" font-size="10">5</text>
  <text x="65" y="275" text-anchor="end" fill="#3E5E80" font-size="10">4</text>
  <text x="65" y="335" text-anchor="end" fill="#3E5E80" font-size="10">3</text>
  <text x="65" y="395" text-anchor="end" fill="#3E5E80" font-size="10">2</text>
  <text x="65" y="455" text-anchor="end" fill="#3E5E80" font-size="10">1</text>
  <text x="65" y="515" text-anchor="end" fill="#3E5E80" font-size="10">0</text>

  <text x="110" y="545" text-anchor="middle" fill="#3E5E80" font-size="10">0</text>
  <text x="170" y="545" text-anchor="middle" fill="#3E5E80" font-size="10">1</text>
  <text x="230" y="545" text-anchor="middle" fill="#3E5E80" font-size="10">2</text>
  <text x="290" y="545" text-anchor="middle" fill="#3E5E80" font-size="10">3</text>
  <text x="350" y="545" text-anchor="middle" fill="#3E5E80" font-size="10">4</text>
  <text x="410" y="545" text-anchor="middle" fill="#3E5E80" font-size="10">5</text>
  <text x="470" y="545" text-anchor="middle" fill="#3E5E80" font-size="10">6</text>
  <text x="530" y="545" text-anchor="middle" fill="#3E5E80" font-size="10">7</text>

  <!-- Grid lines (vertical) -->
  <line x1="80" y1="65" x2="80" y2="530" stroke="#14263E" stroke-width="1"/>
  <line x1="140" y1="65" x2="140" y2="530" stroke="#14263E" stroke-width="1"/>
  <line x1="200" y1="65" x2="200" y2="530" stroke="#14263E" stroke-width="1"/>
  <line x1="260" y1="65" x2="260" y2="530" stroke="#14263E" stroke-width="1"/>
  <line x1="320" y1="65" x2="320" y2="530" stroke="#14263E" stroke-width="1"/>
  <line x1="380" y1="65" x2="380" y2="530" stroke="#14263E" stroke-width="1"/>
  <line x1="440" y1="65" x2="440" y2="530" stroke="#14263E" stroke-width="1"/>
  <line x1="500" y1="65" x2="500" y2="530" stroke="#14263E" stroke-width="1"/>
  <line x1="560" y1="65" x2="560" y2="530" stroke="#14263E" stroke-width="1"/>
  <!-- Grid lines (horizontal) -->
  <line x1="80" y1="65" x2="560" y2="65" stroke="#14263E" stroke-width="1"/>
  <line x1="80" y1="125" x2="560" y2="125" stroke="#14263E" stroke-width="1"/>
  <line x1="80" y1="185" x2="560" y2="185" stroke="#14263E" stroke-width="1"/>
  <line x1="80" y1="245" x2="560" y2="245" stroke="#14263E" stroke-width="1"/>
  <line x1="80" y1="305" x2="560" y2="305" stroke="#14263E" stroke-width="1"/>
  <line x1="80" y1="365" x2="560" y2="365" stroke="#14263E" stroke-width="1"/>
  <line x1="80" y1="425" x2="560" y2="425" stroke="#14263E" stroke-width="1"/>
  <line x1="80" y1="485" x2="560" y2="485" stroke="#14263E" stroke-width="1"/>
  <line x1="80" y1="530" x2="560" y2="530" stroke="#14263E" stroke-width="1"/>

  <!-- Blocked cells (red) at (2,2), (2,3), (3,2), (3,3), (4,4), (4,5) -->
  <rect x="200" y="305" width="60" height="60" fill="#EF5350" opacity="0.35"/>
  <rect x="200" y="365" width="60" height="60" fill="#EF5350" opacity="0.35"/>
  <rect x="260" y="305" width="60" height="60" fill="#EF5350" opacity="0.35"/>
  <rect x="260" y="365" width="60" height="60" fill="#EF5350" opacity="0.35"/>
  <rect x="320" y="185" width="60" height="60" fill="#EF5350" opacity="0.35"/>
  <rect x="320" y="245" width="60" height="60" fill="#EF5350" opacity="0.35"/>
  <text x="230" y="340" text-anchor="middle" fill="#EF5350" font-size="9">BLK</text>
  <text x="350" y="220" text-anchor="middle" fill="#EF5350" font-size="9">BLK</text>

  <!-- Source cell (0,0) — green -->
  <rect x="80" y="485" width="60" height="45" fill="#43A047" opacity="0.5"/>
  <text x="110" y="513" text-anchor="middle" fill="#43A047" font-size="10" font-weight="600">SRC</text>
  <text x="110" y="525" text-anchor="middle" fill="#43A047" font-size="9">g=0</text>

  <!-- Target cell (7,7) — green -->
  <rect x="500" y="65" width="60" height="60" fill="#43A047" opacity="0.5"/>
  <text x="530" y="93" text-anchor="middle" fill="#43A047" font-size="10" font-weight="600">TGT</text>
  <text x="530" y="107" text-anchor="middle" fill="#43A047" font-size="9">h=0</text>

  <!-- Routed path cells (cyan) — path goes around blocked region -->
  <!-- (0,0)→(1,0)→(1,1)→(1,2)→(1,3)→(1,4)→(1,5)→(2,5)→(3,5)→(4,5)→(5,5)→(5,6)→(6,6)→(7,6)→(7,7) -->
  <!-- Render path cells with slight fill -->
  <rect x="140" y="485" width="60" height="45" fill="#00C4E8" opacity="0.15"/>
  <rect x="140" y="425" width="60" height="60" fill="#00C4E8" opacity="0.15"/>
  <rect x="140" y="365" width="60" height="60" fill="#00C4E8" opacity="0.15"/>
  <rect x="140" y="305" width="60" height="60" fill="#00C4E8" opacity="0.15"/>
  <rect x="140" y="245" width="60" height="60" fill="#00C4E8" opacity="0.15"/>
  <rect x="140" y="185" width="60" height="60" fill="#00C4E8" opacity="0.15"/>
  <rect x="200" y="185" width="60" height="60" fill="#00C4E8" opacity="0.15"/>
  <rect x="260" y="185" width="60" height="60" fill="#00C4E8" opacity="0.15"/>
  <rect x="380" y="185" width="60" height="60" fill="#00C4E8" opacity="0.15"/>
  <rect x="380" y="125" width="60" height="60" fill="#00C4E8" opacity="0.15"/>
  <rect x="440" y="125" width="60" height="60" fill="#00C4E8" opacity="0.15"/>
  <rect x="500" y="125" width="60" height="60" fill="#00C4E8" opacity="0.15"/>

  <!-- Path line (cyan arrows) -->
  <polyline points="110,512 170,512 170,455 170,395 170,335 170,275 170,215 230,215 290,215 410,215 410,155 470,155 530,155 530,95"
    fill="none" stroke="#00C4E8" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"/>

  <!-- Cost labels on selected cells -->
  <text x="170" y="472" text-anchor="middle" fill="#00C4E8" font-size="8">g=1</text>
  <text x="170" y="412" text-anchor="middle" fill="#00C4E8" font-size="8">g=2</text>
  <text x="170" y="352" text-anchor="middle" fill="#00C4E8" font-size="8">g=3</text>
  <text x="170" y="292" text-anchor="middle" fill="#00C4E8" font-size="8">g=4</text>
  <text x="170" y="232" text-anchor="middle" fill="#00C4E8" font-size="8">g=5</text>
  <text x="230" y="232" text-anchor="middle" fill="#00C4E8" font-size="8">g=6</text>
  <text x="290" y="232" text-anchor="middle" fill="#00C4E8" font-size="8">g=7</text>
  <text x="410" y="232" text-anchor="middle" fill="#00C4E8" font-size="8">g=8</text>
  <text x="410" y="172" text-anchor="middle" fill="#00C4E8" font-size="8">g=9</text>
  <text x="470" y="172" text-anchor="middle" fill="#00C4E8" font-size="8">g=10</text>
  <text x="530" y="172" text-anchor="middle" fill="#00C4E8" font-size="8">g=11</text>

  <!-- Legend -->
  <rect x="610" y="80" width="14" height="14" fill="#43A047" opacity="0.7"/>
  <text x="630" y="92" fill="#B8D0E8" font-size="11">Source / Target</text>
  <rect x="610" y="104" width="14" height="14" fill="#EF5350" opacity="0.5"/>
  <text x="630" y="116" fill="#B8D0E8" font-size="11">Blocked (device/obstacle)</text>
  <rect x="610" y="128" width="14" height="14" fill="#00C4E8" opacity="0.25"/>
  <text x="630" y="140" fill="#B8D0E8" font-size="11">Routed path cells</text>
  <line x1="610" y1="154" x2="624" y2="154" stroke="#00C4E8" stroke-width="2.5"/>
  <text x="630" y="158" fill="#B8D0E8" font-size="11">Path wire</text>
  <text x="610" y="192" fill="#3E5E80" font-size="10">g = cost-from-source</text>
  <text x="610" y="208" fill="#3E5E80" font-size="10">h = Manhattan to target</text>
  <text x="610" y="224" fill="#3E5E80" font-size="10">f = g + h (priority queue key)</text>

  <!-- Axis labels -->
  <text x="320" y="560" text-anchor="middle" fill="#B8D0E8" font-size="11">track_a (preferred direction X)</text>
  <text x="30" y="300" text-anchor="middle" fill="#B8D0E8" font-size="11" transform="rotate(-90,30,300)">track_b (cross direction Y)</text>
</svg>
```

---

## Priority Queue Implementation

The open set is a `std.PriorityQueue(HeapEntry, void, heapLessThan)` — a Zig standard library binary min-heap.

```zig
HeapEntry = { f_cost: f32, g_cost: f32, node: GridNode }

heapLessThan: Order(a.f_cost, b.f_cost)
```

**Tie-breaking**: The current implementation does not break ties explicitly. When `f_cost(a) == f_cost(b)`, the heap ordering is arbitrary. In practice this is rare given floating-point costs, but could be improved by using `g_cost` as a tiebreaker (prefer nodes with higher g — further from source — to reduce open set size).

The open set uses `defer open.deinit()` for cleanup. The `gMap` (best known g), `cameFrom`, and `closed` maps are all `AutoHashMap(NodeKey, ...)` allocated from the same arena.

---

## Congestion Model

Congestion is stored as a `u8` per grid cell, representing the number of nets that have been routed through that cell. It is updated by the `DetailedRouter` after each net is committed: for each node in the routed path, `grid.cellAtMut(node).congestion += 1`.

During A* expansion, the congestion penalty is applied:

```
congestion_penalty = congestion_weight * cell.congestion
```

Default `congestion_weight = 0.5`. This means a cell used by 2 nets costs `1.0` extra per expansion step — roughly equivalent to one additional track pitch. Cells used by many nets become progressively more expensive, steering later nets around congested regions.

**Congestion feedback**: After all digital nets are routed, the congestion map can be used to identify hotspots. Future work: iterative rip-up-and-reroute using congestion as the primary cost driver.

---

## Via Cost Details

The via cost model accounts for the fact that different metal layers have different pitches. A via between a fine-pitch lower layer and a coarse-pitch upper layer represents more equivalent "distance" than a via between layers with the same pitch:

```
via_transition_cost = via_cost * max(1.0, upper_pitch / lower_pitch)
```

Default `via_cost = 3.0`. This means a via between M1 (fine) and M2 (medium) costs slightly more than a same-layer step, while a via between M3 and M4 (where M4 is wider pitch) costs more.

**Via offset handling**: When descending from layer L to L-1, the projected landing position on L-1 may not align exactly with an L-1 track. The router tries the center landing plus all 8 neighbors in a 3×3 grid. Off-center landings incur an additional `lower_pitch * 0.5` penalty.

---

## Wrong-Way Cost

Each metal layer has a preferred routing direction (H or V). Moving in the non-preferred direction is penalized by `wrong_way_cost` (default 3.0×):

```
preferred move:  step_cost = pitch
cross move:      step_cost = cross_pitch * wrong_way_cost
```

This steers routes into the preferred direction on each layer, producing the canonical "H on odd layers, V on even layers" routing style. The penalty can be reduced (toward 1.0) when the router needs more flexibility.

---

## Pin Access (`pin_access.zig`)

Before A* routing begins, the `PinAccessDB` computes access points for each pin. A pin access point is the nearest routable `GridNode` on the appropriate layer to the physical pin geometry. Access points are pre-computed once and reused for all routes that touch each pin.

Pin access handles:
- M1 pads (250 nm squares at pin positions) mapped to M1 grid tracks
- Off-grid pin positions snapped to nearest track
- Blocked-cell detection: if the nearest grid cell is blocked by a device, the next-nearest reachable cell is used

---

## Blocked Cell Handling

Device bounding boxes are marked in the grid as `blocked = true` during `MultiLayerGrid.init`. The `isCellRoutable(node, net)` predicate returns false for:

1. Cells outside grid bounds
2. Cells marked as blocked (by device or explicit obstacle)
3. Cells reserved for a different net (used to prevent crossing an already-routed net's exclusive zone)

Blocked cells are never added to the open set, so the path automatically routes around them.

---

## Edge Cases

| Scenario | Handling |
|---|---|
| Source == target | Fast path: return 1-node path immediately |
| No path exists | Open set drains to empty; `findPath` returns `null` |
| Near-target acceptance | Accept if same layer and within 1 track in both dims |
| Via grid quantization | 3×3 neighborhood search for valid landing |
| All neighbors blocked | Node is a dead end; A* backtracks via came-from map |
| Congested area | High congestion cost steers path around; may choose suboptimal path length |
| DRC soft penalty | Added to step cost; hard violation blocks the cell entirely |

---

## Data Flow from A* to Route Storage

After `findPath` returns a `RoutePath`, the `DetailedRouter` converts the node sequence to geometry:

```
For each adjacent pair (nodes[i], nodes[i+1]):
  if nodes[i].layer == nodes[i+1].layer:
    append horizontal or vertical segment to RouteArrays
  else:
    append via (zero-length segment on cut layer)
    update congestion on both layers
```

Segment width = `layerWidth(pdk, grid_layer)` = `pdk.min_width[grid_layer]`.

The `RoutePath` allocates its `[]GridNode` from the A* instance's allocator; the caller is responsible for calling `path.deinit()` to free it.
