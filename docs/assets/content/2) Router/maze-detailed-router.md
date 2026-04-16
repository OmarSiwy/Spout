# Maze / Detailed Router — Deep Dive

## Overview

Spout has two routing engines that operate at the "detailed" level:

1. **`MazeRouter`** (`maze.zig`) — a channel-based router that produces a fixed topology: M1 horizontal trunk lines plus M2 L-shaped jogs to connect each pin. Designed for simplicity and LVS correctness in small netlists.
2. **`DetailedRouter`** (`detailed.zig`) — a full Steiner-tree + A* router for multi-layer, multi-net routing with inline DRC. Handles arbitrary net topologies.

Both routers write to `RouteArrays` and use the same layer index convention (0=LI, 1=M1, 2=M2, ..., 5=M5).

---

## MazeRouter (`maze.zig`)

The `MazeRouter` uses a channel-based approach that avoids the complexity of a general maze solver:

### Topology

```
For each net:
  One horizontal M1 "trunk" line at a y-offset outside the device M1 geometry zone
  One vertical M2 "jog column" at an x-offset to the right of all device pins
  One short M2 horizontal segment at the pin y-coordinate to the jog column
  One M1 stub at each pin position connecting to the device M1 pad
```

This topology guarantees that M1 trunk lines from different nets never intersect (they are on different y-offsets), and M2 jog columns from different nets never intersect (they are on different x-offsets).

### Channel Pitch Computation

M1 trunk pitch must be large enough for both DRC and LVS snap tolerance:

```
m1w  = pdk.min_width[M1_pdk_idx]   -- 0.14 µm for SKY130
m1s  = pdk.min_spacing[M1_pdk_idx] -- 0.14 µm
lvs_snap_m1 = 0.1 µm               -- LVS point-near-segment tolerance

pitch = max(m1w + 2*lvs_snap_m1 + m1s, 0.48) + 0.001
      = max(0.14 + 0.2 + 0.14, 0.48) + 0.001
      = 0.481 µm (minimum)
```

The LVS snap tolerance (100 nm) must be doubled because it applies on both sides of a trunk line. Two trunks separated by exactly `pitch` will not cause false LVS shorts.

### M2 Jog Column Pitch

```
m2w  = pdk.min_width[M2_pdk_idx]   -- 0.14 µm
m2s  = pdk.min_spacing[M2_pdk_idx] -- 0.14 µm
lvs_snap = 0.1 µm

m2_jog_pitch = max(m2w + 2*lvs_snap + m2s, 0.48) + 0.001 = 0.481 µm

jog_clearance = m2w/2 + lvs_snap + m2s + 0.001
              = 0.07 + 0.1 + 0.14 + 0.001 = 0.311 µm

jog_col_base = all_pin_xmax + jog_clearance
```

The first jog column is placed at `jog_col_base`, with subsequent columns at `jog_col_base + i * m2_jog_pitch`.

### Trunk Placement

Trunks are placed outside the device M1 geometry clearance zone:

```
dev_m1_ymin = min y of all pin M1 pads - pad_half (0.125 µm)
dev_m1_ymax = max y of all pin M1 pads + pad_half

half_clear = pitch/2 + 0.001

below_start = dev_m1_ymin - half_clear   (first trunk below devices)
above_start = dev_m1_ymax + half_clear   (first trunk above devices)
```

Nets are assigned alternately below and above the device zone, fanning outward. This prevents trunk congestion at one side.

### Trunk Clearance from Other-Net Pins

A trunk for net N must not land within `half_m1w + lvs_snap` of any other net's pin y-coordinate. If a proposed trunk y-position is too close to another net's pin, it is shifted outward until clear. This prevents LVS from false-detecting a trunk of net A as connected to a pin of net B.

---

## DetailedRouter (`detailed.zig`)

The `DetailedRouter` handles the general multi-layer case using A* on `MultiLayerGrid`.

### Net Ordering

```zig
NetOrder = {
  net_idx: u32
  is_power: bool    -- VDD, VSS, power rails
  hpwl: f32         -- half-perimeter wire length of bounding box of pins
  fanout: u16        -- number of pins
}
```

Sort order: power nets first → ascending HPWL → ascending fanout. Power nets go first because they form low-impedance ground planes that act as shielding obstacles and routing guides for signal nets.

### Per-Net Routing Flow

For each net in sorted order:

1. **Collect pins** — gather all `PinIdx` from `PinEdgeArrays` for this net, look up world positions from `DeviceArrays`
2. **Build Steiner tree** — `SteinerTree.build(pin_positions)` returns a list of edges (pairs of world coordinates)
3. **Snap to grid** — convert each Steiner edge endpoint to `GridNode` via `grid.worldToNode()`
4. **Route each Steiner edge** — call `astar.findPath(grid, src_node, tgt_node, net)`; if `null` returned, record failure
5. **Commit path** — convert `RoutePath.nodes` to route segments; append to `RouteArrays`; update congestion in grid cells
6. **Track statistics** — increment `astar_ok` or `astar_fail`

### Rip-Up and Reroute

The current implementation does not perform explicit rip-up and reroute (RR). If `findPath` returns `null` for a net, that net is recorded as unrouted and routing continues with the next net. A future enhancement would:

1. Identify unrouted or DRC-violating nets
2. Rip up (remove their segments from `RouteArrays` and decrement congestion)
3. Re-insert them into the routing queue at increased priority
4. Re-route with higher `congestion_weight` to force new paths

### Steiner Edge Routing Diagram

```svg
<svg viewBox="0 0 820 520" xmlns="http://www.w3.org/2000/svg" font-family="'Inter', 'Segoe UI', sans-serif">
  <title>Maze Router — Layers, Tracks, Vias</title>
  <rect width="820" height="520" fill="#060C18"/>
  <text x="14" y="24" fill="#3E5E80" font-size="11" font-style="italic">Detailed Router — Multi-layer routing with vias</text>

  <!-- Layer labels on left -->
  <text x="30" y="120" text-anchor="middle" fill="#EF5350" font-size="12" font-weight="600">M1</text>
  <text x="30" y="270" text-anchor="middle" fill="#1E88E5" font-size="12" font-weight="600">M2</text>
  <text x="30" y="420" text-anchor="middle" fill="#AB47BC" font-size="12" font-weight="600">M3</text>
  <text x="30" y="100" text-anchor="middle" fill="#3E5E80" font-size="9">(H pref)</text>
  <text x="30" y="250" text-anchor="middle" fill="#3E5E80" font-size="9">(V pref)</text>
  <text x="30" y="400" text-anchor="middle" fill="#3E5E80" font-size="9">(H pref)</text>

  <!-- M1 layer: horizontal tracks -->
  <rect x="60" y="70" width="720" height="90" rx="4" fill="#09111F" stroke="#14263E"/>
  <!-- M1 horizontal tracks -->
  <line x1="70" y1="90" x2="760" y2="90" stroke="#EF5350" stroke-width="0.5" opacity="0.4"/>
  <line x1="70" y1="110" x2="760" y2="110" stroke="#EF5350" stroke-width="0.5" opacity="0.4"/>
  <line x1="70" y1="130" x2="760" y2="130" stroke="#EF5350" stroke-width="0.5" opacity="0.4"/>
  <line x1="70" y1="150" x2="760" y2="150" stroke="#EF5350" stroke-width="0.5" opacity="0.4"/>
  <!-- Routed M1 segment (net A) -->
  <line x1="100" y1="110" x2="500" y2="110" stroke="#EF5350" stroke-width="5" stroke-linecap="round" opacity="0.9"/>
  <text x="300" y="104" text-anchor="middle" fill="#EF5350" font-size="10">Net A — M1 horizontal segment</text>
  <!-- Routed M1 segment (net B) -->
  <line x1="200" y1="130" x2="650" y2="130" stroke="#FB8C00" stroke-width="5" stroke-linecap="round" opacity="0.9"/>
  <text x="450" y="145" text-anchor="middle" fill="#FB8C00" font-size="10">Net B — M1 horizontal segment</text>

  <!-- M2 layer: vertical tracks -->
  <rect x="60" y="190" width="720" height="100" rx="4" fill="#09111F" stroke="#14263E"/>
  <!-- M2 vertical track guides -->
  <line x1="120" y1="195" x2="120" y2="285" stroke="#1E88E5" stroke-width="0.5" opacity="0.4"/>
  <line x1="200" y1="195" x2="200" y2="285" stroke="#1E88E5" stroke-width="0.5" opacity="0.4"/>
  <line x1="280" y1="195" x2="280" y2="285" stroke="#1E88E5" stroke-width="0.5" opacity="0.4"/>
  <line x1="360" y1="195" x2="360" y2="285" stroke="#1E88E5" stroke-width="0.5" opacity="0.4"/>
  <line x1="440" y1="195" x2="440" y2="285" stroke="#1E88E5" stroke-width="0.5" opacity="0.4"/>
  <line x1="520" y1="195" x2="520" y2="285" stroke="#1E88E5" stroke-width="0.5" opacity="0.4"/>
  <line x1="600" y1="195" x2="600" y2="285" stroke="#1E88E5" stroke-width="0.5" opacity="0.4"/>
  <line x1="680" y1="195" x2="680" y2="285" stroke="#1E88E5" stroke-width="0.5" opacity="0.4"/>
  <!-- Routed M2 segment (net A) -->
  <line x1="500" y1="200" x2="500" y2="280" stroke="#EF5350" stroke-width="5" stroke-linecap="round" opacity="0.9"/>
  <text x="520" y="248" fill="#EF5350" font-size="10">Net A — M2 vertical</text>
  <!-- Routed M2 segment (net C) -->
  <line x1="360" y1="195" x2="360" y2="285" stroke="#00C4E8" stroke-width="5" stroke-linecap="round" opacity="0.9"/>
  <text x="375" y="230" fill="#00C4E8" font-size="10">Net C</text>

  <!-- M3 layer: horizontal tracks -->
  <rect x="60" y="340" width="720" height="100" rx="4" fill="#09111F" stroke="#14263E"/>
  <line x1="70" y1="360" x2="760" y2="360" stroke="#AB47BC" stroke-width="0.5" opacity="0.4"/>
  <line x1="70" y1="380" x2="760" y2="380" stroke="#AB47BC" stroke-width="0.5" opacity="0.4"/>
  <line x1="70" y1="400" x2="760" y2="400" stroke="#AB47BC" stroke-width="0.5" opacity="0.4"/>
  <line x1="70" y1="420" x2="760" y2="420" stroke="#AB47BC" stroke-width="0.5" opacity="0.4"/>
  <line x1="70" y1="430" x2="760" y2="430" stroke="#AB47BC" stroke-width="0.5" opacity="0.4"/>
  <!-- Routed M3 segment (net A, continuing from M2 via) -->
  <line x1="500" y1="380" x2="700" y2="380" stroke="#EF5350" stroke-width="5" stroke-linecap="round" opacity="0.9"/>
  <text x="600" y="374" text-anchor="middle" fill="#EF5350" font-size="10">Net A — M3 horizontal (after via)</text>

  <!-- Vias -->
  <!-- Net A: M1@(500,110) -> M2@(500,200) via -->
  <circle cx="500" cy="160" r="7" fill="#43A047" stroke="#B8D0E8" stroke-width="1.5"/>
  <text x="515" y="164" fill="#43A047" font-size="9">V1</text>
  <!-- Net A: M2@(500,280) -> M3@(500,340) via -->
  <circle cx="500" cy="312" r="7" fill="#43A047" stroke="#B8D0E8" stroke-width="1.5"/>
  <text x="515" y="316" fill="#43A047" font-size="9">V2</text>

  <!-- Via lines connecting layers -->
  <line x1="500" y1="160" x2="500" y2="160" stroke="#43A047" stroke-width="2"/>
  <line x1="500" y1="115" x2="500" y2="197" stroke="#43A047" stroke-width="1.5" stroke-dasharray="3,2"/>
  <line x1="500" y1="283" x2="500" y2="340" stroke="#43A047" stroke-width="1.5" stroke-dasharray="3,2"/>

  <!-- Layer bracket annotations -->
  <text x="785" y="120" fill="#EF5350" font-size="10">layer=1</text>
  <text x="785" y="245" fill="#1E88E5" font-size="10">layer=2</text>
  <text x="785" y="395" fill="#AB47BC" font-size="10">layer=3</text>

  <!-- Pin markers -->
  <circle cx="100" cy="110" r="5" fill="#43A047"/>
  <text x="100" y="103" text-anchor="middle" fill="#43A047" font-size="9">Pin A0</text>
  <circle cx="700" cy="380" r="5" fill="#43A047"/>
  <text x="700" y="373" text-anchor="middle" fill="#43A047" font-size="9">Pin A1</text>

  <!-- Via enclosure markers -->
  <rect x="490" y="102" width="20" height="16" rx="2" fill="none" stroke="#43A047" stroke-width="1" stroke-dasharray="2,2" opacity="0.5"/>
  <text x="510" y="178" fill="#3E5E80" font-size="8">enc: 0.06 µm</text>

  <!-- Spacing annotation -->
  <line x1="100" y1="110" x2="100" y2="130" stroke="#B8D0E8" stroke-width="1" stroke-dasharray="2,2"/>
  <line x1="85" y1="110" x2="115" y2="110" stroke="#B8D0E8" stroke-width="0.5"/>
  <line x1="85" y1="130" x2="115" y2="130" stroke="#B8D0E8" stroke-width="0.5"/>
  <text x="75" y="122" text-anchor="end" fill="#B8D0E8" font-size="8">0.20 µm</text>
  <text x="75" y="132" text-anchor="end" fill="#3E5E80" font-size="8">spacing</text>
</svg>
```

---

## Track Assignment per Layer

In the `DetailedRouter`, tracks are not pre-assigned; the A* search finds available tracks dynamically based on grid occupancy and DRC checks. However, preferred-direction routing creates an emergent track structure:

- **M1** (horizontal preferred): most horizontal wires land on M1 tracks
- **M2** (vertical preferred): most vertical runs and jog columns land on M2 tracks
- **M3+**: used for longer routes that need to bypass congestion

The `wrong_way_cost` multiplier (default 3.0) discourages non-preferred moves, creating clean layer separation in practice.

In the `MazeRouter`, track assignment is explicit:

- M1 track assignment = `below_start - (net_order_below * pitch)` or `above_start + (net_order_above * pitch)`
- M2 column assignment = `jog_col_base + net_index * m2_jog_pitch`

---

## Wavefront Expansion Details

The A* expansion maintains four hash maps:

| Map | Key type | Value type | Purpose |
|---|---|---|---|
| `gMap` | `NodeKey (u64)` | `f32` | Best known g-cost per node |
| `cameFrom` | `NodeKey (u64)` | `NodeKey (u64)` | Parent node for path reconstruction |
| `closed` | `NodeKey (u64)` | `void` | Expanded nodes (skip if re-encountered) |
| open set | (heap) | `HeapEntry` | Frontier priority queue |

**Expansion step** (pseudocode):

```
current = open.remove()           -- O(log n) heap pop
if closed.contains(current): continue
closed.insert(current)
if current == target (or near-target): reconstruct and return

for each neighbor of current:
  if closed.contains(neighbor): skip
  tentativeG = current.g + stepCost(current, neighbor) + congestion(neighbor)
  if tentativeG < gMap[neighbor]:
    gMap[neighbor] = tentativeG
    cameFrom[neighbor] = current
    open.add({ f = tentativeG + h(neighbor, target), g = tentativeG, node = neighbor })
```

The total number of nodes expanded is bounded by the grid size × number of layers, but in practice the heuristic keeps it much smaller for reasonable routing topologies.

---

## Via Insertion Rules

Vias are emitted when consecutive path nodes are on different layers:

```
if nodes[i].layer != nodes[i+1].layer:
  via_layer = min(nodes[i].layer, nodes[i+1].layer)  -- cut layer between the two metals
  via_x = world_x of transition point
  via_y = world_y of transition point
  via_width = pdk.via_width[via_layer]               -- e.g. 0.17 µm for M1-M2
  RouteArrays.append(via_layer, via_x, via_y, via_x, via_y, via_width, net)
```

Enclosure rules (`enc_rules` from `pdks/sky130.json`) require that:
- M1 enclosing a via to M2: 0.06 µm on all sides
- M2 enclosing a via from M1: 0.03 µm on all sides

These are enforced in the post-layout DRC pass (`src/characterize/drc.zig`), not in the inline DRC during routing (see open gap #4 in architecture.md).

**SKY130 via sizes:**

| Cut layer | Via size |
|---|---|
| M1-M2 (via.44) | 0.17 µm |
| M2-M3 | 0.17 µm |
| M3-M4 | 0.15 µm |
| M4-M5 | 0.20 µm |

---

## Net Ordering Strategy — Detailed Rationale

Power nets are routed first because:
1. They have fixed net shapes that must not be violated by signal routing
2. They provide return current paths (ground planes on M1, supply rails on M2)
3. Their large shapes mark significant portions of the grid as same-net (which A* can route through)

Short nets (low HPWL) go next because:
1. They are less likely to conflict with other short nets
2. Their routing consumes few grid resources
3. Routing order errors are cheaper to fix for short nets

High-fanout nets go last because:
1. They require the most routing resources
2. Seeing full congestion information first leads to better routing decisions
3. Their blocking effect on other nets is managed by routing them into already-established channels

---

## M1 Pad and M2 Jog Architecture (MazeRouter)

Each pin connection in `MazeRouter.routeAll` produces exactly three route segments:

1. **M1 stub** — a horizontal segment at the pin's y-coordinate, from the pin x to the net's jog column x, at layer 1 (M1). Width = `m1w`.
2. **M2 horizontal jog** — a horizontal segment at the trunk y-coordinate, from the jog column to the trunk x-extent, at layer 2 (M2). Width = `m2w`.
3. **M2 vertical jog** — a vertical segment from the pin y-coordinate to the trunk y-coordinate, at the jog column x, at layer 2 (M2). Width = `m2w`.

Plus, if the pin and trunk have different x positions:
4. **M1 trunk** — a horizontal segment at the trunk y, spanning the full x-extent of the net's pins.

This topology is explicitly designed to keep all M1 in horizontal segments and all M2 in L-shaped connectors, matching the preferred routing directions of each layer.
