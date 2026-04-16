# Analog Routing — Comprehensive Reference

## Overview

Spout's analog router is a purpose-built engine for routing nets that require parasitic symmetry, shielding, isolation, and LDE (Layout-Dependent Effect) control. It is invoked before the digital `DetailedRouter` so that matched nets are committed with full analog constraints before general routing fills the remaining grid.

The analog router is structured around **net groups** — sets of nets that must be routed together with specific constraints. Six group types are supported.

---

## Net Group Types (`analog_types.zig`)

| Type | Enum value | Nets | Constraint | Triggered by |
|---|---|---|---|---|
| `differential` | 0 | exactly 2 | Mirrored topology, <1% length mismatch, via count delta ≤ 1 | Diff pair annotation |
| `matched` | 1 | ≥ 2 | Same R, C, length, via count within tolerance | Current mirror, matched loads |
| `shielded` | 2 | 1 signal + shield | Shield wire on adjacent layer | High-Z node, sensitive signal |
| `kelvin` | 3 | force + sense | No shared segments; force has lowest R | 4-wire resistance measurement |
| `resistor_matched` | 4 | ≥ 2 | Common-centroid resistor routing | Precision resistor arrays |
| `capacitor_array` | 5 | ≥ 2 | Unit cap array routing | DAC, ADC, precision caps |

Groups are stored in `AnalogGroupDB` (see Data Structures section). Groups are validated at insertion time: wrong net counts, invalid tolerances, or missing kelvin force/sense nets return typed errors.

---

## Analog Routing Visualization

```svg
<svg viewBox="0 0 820 580" xmlns="http://www.w3.org/2000/svg" font-family="'Inter', 'Segoe UI', sans-serif">
  <title>Analog Routing — Differential Pair with Shields and Guard Ring</title>
  <rect width="820" height="580" fill="#060C18"/>
  <text x="14" y="24" fill="#3E5E80" font-size="11" font-style="italic">Analog Router — Differential pair, shields, guard ring</text>

  <!-- Guard ring (outer rectangle) -->
  <rect x="60" y="50" width="680" height="460" rx="6" fill="none" stroke="#43A047" stroke-width="3"/>
  <rect x="75" y="65" width="650" height="430" rx="4" fill="none" stroke="#43A047" stroke-width="1.5" stroke-dasharray="6,3" opacity="0.5"/>
  <text x="80" y="46" fill="#43A047" font-size="11" font-weight="600">Guard Ring (P+ / N+ / deep-N-well)</text>
  <text x="80" y="58" fill="#43A047" font-size="9">ring_type = p_plus | n_plus | deep_nwell · net = VSS</text>

  <!-- Well contacts on guard ring (small squares) -->
  <rect x="60" y="90" width="8" height="8" fill="#43A047"/>
  <rect x="60" y="120" width="8" height="8" fill="#43A047"/>
  <rect x="60" y="150" width="8" height="8" fill="#43A047"/>
  <rect x="60" y="180" width="8" height="8" fill="#43A047"/>
  <rect x="60" y="210" width="8" height="8" fill="#43A047"/>
  <rect x="60" y="240" width="8" height="8" fill="#43A047"/>
  <rect x="60" y="270" width="8" height="8" fill="#43A047"/>
  <rect x="60" y="300" width="8" height="8" fill="#43A047"/>
  <rect x="60" y="330" width="8" height="8" fill="#43A047"/>
  <rect x="60" y="360" width="8" height="8" fill="#43A047"/>
  <rect x="60" y="390" width="8" height="8" fill="#43A047"/>
  <rect x="60" y="420" width="8" height="8" fill="#43A047"/>
  <rect x="60" y="450" width="8" height="8" fill="#43A047"/>

  <!-- Contact pitch label -->
  <line x1="52" y1="90" x2="52" y2="120" stroke="#43A047" stroke-width="0.8"/>
  <line x1="48" y1="90" x2="56" y2="90" stroke="#43A047" stroke-width="0.8"/>
  <line x1="48" y1="120" x2="56" y2="120" stroke="#43A047" stroke-width="0.8"/>
  <text x="47" y="107" text-anchor="end" fill="#43A047" font-size="8">pitch</text>

  <!-- Device boxes -->
  <rect x="200" y="200" width="100" height="120" rx="4" fill="#09111F" stroke="#1E88E5" stroke-width="2"/>
  <text x="250" y="258" text-anchor="middle" fill="#1E88E5" font-size="12" font-weight="600">M1</text>
  <text x="250" y="272" text-anchor="middle" fill="#B8D0E8" font-size="10">NMOS</text>
  <text x="250" y="286" text-anchor="middle" fill="#3E5E80" font-size="9">device A</text>

  <rect x="480" y="200" width="100" height="120" rx="4" fill="#09111F" stroke="#1E88E5" stroke-width="2"/>
  <text x="530" y="258" text-anchor="middle" fill="#1E88E5" font-size="12" font-weight="600">M2</text>
  <text x="530" y="272" text-anchor="middle" fill="#B8D0E8" font-size="10">NMOS</text>
  <text x="530" y="286" text-anchor="middle" fill="#3E5E80" font-size="9">device B</text>

  <!-- Pin markers -->
  <circle cx="250" cy="200" r="5" fill="#00C4E8"/>
  <circle cx="530" cy="200" r="5" fill="#00C4E8"/>
  <text x="250" y="195" text-anchor="middle" fill="#00C4E8" font-size="8">D+</text>
  <text x="530" y="195" text-anchor="middle" fill="#00C4E8" font-size="8">D−</text>

  <!-- Net P trace (cyan) -->
  <polyline points="250,200 250,150 390,150"
    fill="none" stroke="#00C4E8" stroke-width="5" stroke-linecap="round" stroke-linejoin="round"/>
  <!-- Net N trace (cyan, same color = matched) -->
  <polyline points="530,200 530,150 390,150"
    fill="none" stroke="#00C4E8" stroke-width="5" stroke-linecap="round" stroke-linejoin="round"/>

  <!-- Length labels -->
  <line x1="250" y1="138" x2="390" y2="138" stroke="#00C4E8" stroke-width="0.8" stroke-dasharray="3,2"/>
  <line x1="250" y1="134" x2="250" y2="142" stroke="#00C4E8" stroke-width="0.8"/>
  <line x1="390" y1="134" x2="390" y2="142" stroke="#00C4E8" stroke-width="0.8"/>
  <text x="320" y="134" text-anchor="middle" fill="#00C4E8" font-size="9">L_P = 190 µm</text>

  <line x1="530" y1="138" x2="390" y2="138" stroke="#00C4E8" stroke-width="0.8" stroke-dasharray="3,2"/>
  <line x1="390" y1="130" x2="390" y2="162" stroke="#00C4E8" stroke-width="0.8"/>
  <text x="460" y="130" text-anchor="middle" fill="#00C4E8" font-size="9">L_N = 190 µm ✓</text>

  <!-- Shield wires (amber/orange, on adjacent layer M2) -->
  <!-- Shield above net P trace -->
  <polyline points="250,130 250,100 390,100"
    fill="none" stroke="#FB8C00" stroke-width="3" stroke-linecap="round" stroke-linejoin="round" opacity="0.8"/>
  <!-- Shield below net P trace -->
  <polyline points="250,170 250,185 390,185"
    fill="none" stroke="#FB8C00" stroke-width="3" stroke-linecap="round" stroke-linejoin="round" opacity="0.8"/>
  <!-- Shield above net N trace -->
  <polyline points="530,130 530,100 390,100"
    fill="none" stroke="#FB8C00" stroke-width="3" stroke-linecap="round" stroke-linejoin="round" opacity="0.8"/>
  <!-- Shield below net N trace -->
  <polyline points="530,170 530,185 390,185"
    fill="none" stroke="#FB8C00" stroke-width="3" stroke-linecap="round" stroke-linejoin="round" opacity="0.8"/>

  <!-- Shield labels -->
  <text x="200" y="97" text-anchor="end" fill="#FB8C00" font-size="10">Shield (VSS, M2)</text>
  <text x="200" y="188" text-anchor="end" fill="#FB8C00" font-size="10">Shield (VSS, M2)</text>

  <!-- Shield spacing annotation -->
  <line x1="135" y1="100" x2="135" y2="150" stroke="#FB8C00" stroke-width="0.8"/>
  <line x1="131" y1="100" x2="139" y2="100" stroke="#FB8C00" stroke-width="0.8"/>
  <line x1="131" y1="150" x2="139" y2="150" stroke="#FB8C00" stroke-width="0.8"/>
  <text x="130" y="128" text-anchor="end" fill="#FB8C00" font-size="8">spacing</text>

  <!-- Centroid axis (vertical dotted) -->
  <line x1="390" y1="70" x2="390" y2="490" stroke="#3E5E80" stroke-width="1.5" stroke-dasharray="8,4"/>
  <text x="395" y="490" fill="#3E5E80" font-size="9">centroid axis</text>

  <!-- Jog on net P to balance length (if needed) -->
  <!-- Dummy via markers on net P -->
  <circle cx="300" cy="150" r="4" fill="none" stroke="#AB47BC" stroke-width="1.5"/>
  <text x="300" y="142" text-anchor="middle" fill="#AB47BC" font-size="8">via</text>

  <!-- Legend -->
  <rect x="630" y="80" width="14" height="4" rx="1" fill="#00C4E8"/>
  <text x="650" y="87" fill="#B8D0E8" font-size="11">Matched signal traces (Net P, Net N)</text>
  <rect x="630" y="100" width="14" height="4" rx="1" fill="#FB8C00"/>
  <text x="650" y="107" fill="#B8D0E8" font-size="11">Shield wires (adjacent layer, VSS)</text>
  <rect x="630" y="120" width="14" height="14" rx="2" fill="none" stroke="#43A047" stroke-width="2"/>
  <text x="650" y="131" fill="#B8D0E8" font-size="11">Guard ring (P+ contacts)</text>
  <line x1="630" y1="152" x2="644" y2="152" stroke="#3E5E80" stroke-width="1.5" stroke-dasharray="5,3"/>
  <text x="650" y="156" fill="#B8D0E8" font-size="11">Centroid symmetry axis</text>
  <circle cx="637" cy="172" r="4" fill="none" stroke="#AB47BC" stroke-width="1.5"/>
  <text x="650" y="176" fill="#B8D0E8" font-size="11">Via (for layer transition)</text>
</svg>
```

---

## Matched Routing (`matched_router.zig`, `symmetric_steiner.zig`)

### Symmetric Steiner Tree

For differential and matched groups, the `SymmetricSteiner` produces mirror-image topologies:

```
SymmetricSteiner = {
  pins_p:      []const Pin    -- positive-net pin positions [x, y]
  pins_n:      []const Pin    -- negative-net pin positions [x, y]
  axis:        SymmetryAxis   -- .x or .y (which axis to mirror around)
  axis_value:  f32            -- coordinate value of the centroid axis
  edges_p:     []Segment      -- Steiner tree segments for net P
  edges_n:     []Segment      -- Steiner tree segments for net N (mirror of P)
}
```

**Build algorithm**:
1. Compute centroid axis: `axis_value = (center_p + center_n) / 2` along the chosen axis
2. Build Steiner tree for net P using `steiner.zig` (Prim's MST on Hanan grid)
3. Mirror each edge around the centroid axis: if axis = `.y`, reflect each x-coordinate as `x' = 2*axis_value - x`
4. Result: net N has identical topology and wire lengths as net P

`Segment = { x1, y1, x2, y2 }`. `totalLength(.p)` and `totalLength(.n)` are computed as the sum of segment lengths (`sqrt(dx² + dy²)` per segment).

### MatchedRouter Algorithm

```
routeGroup(group):
  1. Build SymmetricSteiner tree
  2. For each Steiner edge (src, dst):
     - astar.findPath(grid, src_node, dst_node, net_p, matchedCostFn)
     - astar.findPath(grid, mirror(src_node), mirror(dst_node), net_n, matchedCostFn)
  3. Collect all segments into segments_p / segments_n
  4. Compute via counts from layer transitions
  5. Call balanceWireLengths()
  6. Call balanceViaCounts()
```

### Matched Cost Function Extension

The standard A* cost function is extended with a `MatchedCostFn` when routing the second net of a pair:

```zig
MatchedCostFn = {
  partner_net:     NetIdx       -- the already-routed paired net
  partner_path:    ?[]GridNode  -- partner's routed path (for mismatch calc)
  mismatch_penalty: f32         -- cost added when current length diverges from partner
  via_penalty:     f32          -- per-via penalty for balancing
  same_layer_bonus: f32         -- reward for staying on preferred_layer
  preferred_layer: u8
}
```

This adds:
- **Layer-change cost** when partner is on a different layer → steers both nets to the same layer
- **Mismatch cost** when current accumulated length diverges from partner's path at the same progress fraction
- **Same-layer bonus** when node is on `preferred_layer`

### Wire-Length Balancing

After both nets are routed, `balanceWireLengths` equalizes lengths:

```
len_p = sum of segment lengths for net P
len_n = sum of segment lengths for net N
delta = |len_p - len_n|

if delta > tolerance * max(len_p, len_n):
  find longest "silent" segment on shorter net
  (silent = not on critical timing path, not a stub)
  add L-shaped jog (detour) to that segment
  marked is_jog = true in SegmentFlags
  repeat until ratio < tolerance
```

Tolerance defaults to 0.01 (1%). Exit criterion: differential pair routes with <1% length mismatch.

### Via Count Balancing

```
vias_p = count zero-length segments on net P (via markers)
vias_n = count zero-length segments on net N
delta = |vias_p - vias_n|

if delta > 1:
  find DRC-clean silent segment on net with fewer vias
  insert dummy via pair (down + up on adjacent layers)
  marked is_dummy_via = true
  check DRC before committing; skip if spacing violation
```

Exit criterion: via count delta ≤ 1.

### MatchedRoutingCost Parameters

| Field | Default | Description |
|---|---|---|
| `base_cost` | = pitch | Standard A* movement cost |
| `mismatch_penalty` | tunable | Wire-length mismatch penalty |
| `via_penalty` | tunable | Per-via penalty for balancing |
| `same_layer_bonus` | tunable | Reward for staying on preferred layer |

---

## Shielded Routing (`shield_router.zig`)

### Shield Wire Generation

For nets annotated as `shielded`, shield wires are placed on the adjacent metal layer:

```
routeShielded(signal_net, shield_net, signal_layer):
  shield_layer = signal_layer + 1  (wraps at num_metal_layers)
  shield_width = max(signal_width, min_width[shield_layer])

  For each routed signal segment on signal_layer:
    Compute shield rect on shield_layer:
      shield = signal_rect expanded by min_spacing[shield_layer] on each side
    Query SpatialGrid/InlineDrcChecker for conflicts on shield_layer
    If no conflict:
      Append shield segment to ShieldDB with shield_net, is_driven=false
    Else:
      Skip (gap in shield continuity is acceptable)
```

### Driven Guard Variant

`routeDrivenGuard(signal_net, guard_net, shield_layer)` is identical but sets `shield_net = signal_net` (same potential, not VSS). Used for high-impedance nodes where AC ground is needed but no DC connection to VSS exists. `is_driven = true` in the ShieldDB record.

### Geometry Rules

| Rule | Value |
|---|---|
| Shield layer | `signal_layer + 1 mod num_metal_layers` |
| Shield width | `max(signal_width, pdk.min_width[shield_layer])` |
| Shield expansion | `pdk.min_spacing[shield_layer]` on each side |
| Min shield segment length | `2 * via_pitch` (must fit contacts on both ends) |

### Edge Cases

| Scenario | Handling |
|---|---|
| Top metal layer (no layer+1) | No shield generated; warning logged |
| DRC conflict on shield rect | Segment skipped (gap allowed) |
| Signal segment too short for via pitch | Skip — cannot place contacts both ends |
| Shield layer occupied by other signal | Skip via stitching for that segment |

### ShieldDB Layout

SoA table in `shield_router.zig`:

| Column | Type | Description |
|---|---|---|
| x1, y1, x2, y2 | f32 | Shield wire geometry |
| width | f32 | Shield wire width |
| layer | u8 | Shield metal layer |
| shield_net | NetIdx | Ground or guard net |
| signal_net | NetIdx | Signal being shielded |
| is_driven | bool | True if driven guard (not grounded) |

---

## Guard Ring Insertion (`guard_ring.zig`)

### Purpose

Guard rings provide substrate isolation:
- **P+ rings** — collect minority carriers in N-substrate; tie to VSS
- **N+ rings** — collect holes in P-well; tie to VDD
- **Deep N-well rings** — triple-well isolation; protect analog from digital substrate noise
- **Composite** — P+ ring inside deep N-well ring (strongest isolation)

### Donut Geometry

A guard ring is a rectangular donut:

```
outer: (bbox_x1, bbox_y1) to (bbox_x2, bbox_y2)
inner: (inner_x1, inner_y1) to (inner_x2, inner_y2)

Ring area = outer_rect - inner_rect
```

Generated as four rectangular segments:
- **Top**: `(inner_x1, inner_y2)` to `(inner_x2, bbox_y2)` — spans full width
- **Bottom**: `(inner_x1, bbox_y1)` to `(inner_x2, inner_y1)`
- **Left**: `(bbox_x1, inner_y1)` to `(inner_x1, inner_y2)` — shorter, excludes corners
- **Right**: `(inner_x2, inner_y1)` to `(bbox_x2, inner_y2)`

### Insert Algorithm

```
insert(region, ring_type, net):
  outer = region + guard_ring_width + guard_ring_spacing
  inner = region + guard_ring_spacing
  validate inner > region (positive ring width)
  generate 4 donut segments
  place contacts at contact_pitch along each segment
    via type determined by ring_type and layer
    deep N-well uses stacked contacts (LI + M1)
  register with DRC checker (if enabled)
  return GuardRingIdx
```

### Stitch-In for Existing Metal

When an existing VSS rail overlaps the ring path:

```
insertWithStitchIn(region, ring_type, net, existing_metal):
  compute normal ring geometry
  for each overlap region:
    split ring at overlap into two segments with gap = guard_ring_spacing
    add contacts on both sides of gap (stitch-in contacts)
  set has_stitch_in = true
```

### GuardRingDB Layout

| Column | Type | Description |
|---|---|---|
| bbox_x1/y1/x2/y2 | f32 | Outer bounding box |
| inner_x1/y1/x2/y2 | f32 | Inner rect (donut hole) |
| ring_type | GuardRingType (u8) | p_plus / n_plus / deep_nwell / composite |
| net | NetIdx | Connected net (VSS or VDD) |
| contact_pitch | f32 | Spacing between contacts |
| has_stitch_in | bool | True if ring overlaps existing metal |

### Deep N-Well Merging

Adjacent analog blocks may share a single deep N-well region:

```
mergeDeepNWell(ring_a, ring_b):
  if ring_a.ring_type == deep_nwell and ring_b.ring_type == deep_nwell:
    outer = union(ring_a.outer, ring_b.outer)
    inner = union(ring_a.inner, ring_b.inner)
    replace both with single merged ring
```

---

## Thermal-Aware Routing (`thermal.zig`)

### ThermalMap

A 2D grid of `f32` temperatures covering the die, `cell_size = 10 µm`:

```
ThermalMap = {
  temps:    []f32      -- row-major, cell(x,y) = temps[y * cols + x]
  rows:     u32
  cols:     u32
  cell_size: f32       -- typically 10.0 µm
  ambient:  f32        -- baseline temperature
}
```

**Query** is O(1): `col = (x - bbox_x1) / cell_size`, clamp to bounds, index.

### Hotspot Model

Gaussian diffusion from user-supplied hotspot locations:

```
addHotspot(x, y, delta_T, radius):
  For each cell within radius:
    distance = sqrt(dx² + dy²)
    temps[cell] += delta_T * exp(-distance² / (2 * radius²))
```

### Thermal Cost in A*

During matched routing, thermal gradient penalizes paths that cross isotherms:

```
thermal_cost(a, b) = |temp(a) - temp(b)| * weight
```

Zero cost for same-isotherm routing. The weight is tunable (default 1.0). This cost is added to the A* step cost, steering both nets of a differential pair along the same isotherm.

### Isotherm Extraction

`extractIsotherm(temperature)` returns axis-aligned rectangles near the target isotherm — cells within ±0.1°C of the target temperature. Used to visualize thermal zones and verify that matched nets route along the same contour.

---

## LDE (Layout Dependent Effects) Routing (`lde.zig`)

### What LDE Is

LDE effects modify MOSFET characteristics based on proximity to other active regions:

- **LOD** (Length of Diffusion / OD proximity): Vt shift based on how far a device is from the edge of active diffusion
- **WPE** (Well Proximity Effect): Vt shift based on how close the device is to the well boundary
- **SA/SB** spacing: gate-to-STI distance on source side (SA) and body side (SB)

Matched devices must have symmetric SA/SB values to avoid threshold voltage mismatch.

### LDE Constraint Database

`LDEConstraintDB` stores per-device SA/SB constraints:

| Column | Type | Description |
|---|---|---|
| device | DeviceIdx | Device this applies to |
| min_sa | f32 | Minimum SA (source to active edge) in µm |
| max_sa | f32 | Maximum SA |
| min_sb | f32 | Minimum SB (body to active edge) in µm |
| max_sb | f32 | Maximum SB |
| sc_target | f32 | SCA (active to well edge) target for WPE |

### Keepout Zone Generation

```
generateKeepouts(device_bboxes):
  For each device with constraint:
    sa_keepout = expand device_bbox by min_sa on source-facing side
    sb_keepout = expand device_bbox by min_sb on body-facing side
    combined = union(sa_keepout, sb_keepout)
    append to keepout list
```

Device side orientation: NMOS → left=source, right=body; PMOS → right=source, left=body.

These keepout rectangles are registered with the spatial grid as obstacles, preventing routing from altering the effective SA/SB distances.

### LDE Cost Function

For matched devices A and B, the cost penalizes SA/SB asymmetry:

```
computeLDECost(sa_a, sb_a, sa_b, sb_b) =
  |sa_a - sa_b| + |sb_a - sb_b|

computeLDECostScaled(sa_a, sb_a, sa_b, sb_b, tolerance) =
  max(0, |sa_a - sa_b| - tolerance) + max(0, |sb_a - sb_b| - tolerance)
```

Zero cost = perfectly symmetric SA/SB. The scaled variant ignores differences within tolerance, avoiding over-penalization for minor variations.

---

## PEX Feedback Loop (`pex_feedback.zig`)

### Purpose

The PEX (Parasitic EXtraction) feedback loop closes the analog matching gap by iterating:

```
route → extract → measure mismatch → repair → re-route (max 5 iterations)
```

### NetResult

Per-net extraction result:

```zig
NetResult = {
  net_id:    u32   -- net identifier
  total_r:   f32   -- sum of resistance elements (Ω)
  total_c:   f32   -- sum of capacitance to substrate (fF)
  via_count: u32   -- number of via transitions
  seg_count: u32   -- number of route segments
  length:    f32   -- total wire length (µm)
}
```

### MatchReport

Per-group match analysis:

```zig
MatchReport = {
  group_idx:      AnalogGroupIdx
  passes:         bool           -- true iff all ratios ≤ tolerance
  r_ratio:        f32            -- |R_a - R_b| / max(R_a, R_b)
  c_ratio:        f32            -- |C_a - C_b| / max(C_a, C_b)
  length_ratio:   f32            -- |L_a - L_b| / max(L_a, L_b)
  via_delta:      i32            -- via_count_a - via_count_b (signed)
  coupling_delta: f32            -- coupling cap difference (fF)
  tolerance:      f32            -- from group spec
}
```

### Repair Dispatch

When a group fails, `repairFromPexReport` applies targeted repairs:

| Failing metric | Repair action |
|---|---|
| R mismatch | `adjust_widths` — widen to reduce R, narrow to increase R |
| C mismatch | `adjust_layers` — move to different metal layer (different dielectric distance) |
| Length mismatch | `add_jogs` — add silent jogs to shorter net |
| Via count delta | `add_dummy_vias` — insert dummy via pairs where DRC-clean |
| Coupling mismatch | `rebalance_layer` — reassign layers to reduce coupling |

### Convergence

The loop exits when all groups pass tolerance OR `max_iterations` (5) is reached:

```
PexFeedbackResult = {
  iterations: u8          -- actual iterations run (1–5)
  reports:    []MatchReport  -- final state of all groups
}
```

`RoutingResult = success | mismatch_exceeded | no_path | max_iterations`

---

## AnalogGroupDB — Data Layout Reference

Full SoA layout of `AnalogGroupDB` (in `analog_groups.zig`):

**Hot fields** (touched every routing iteration):

| Column | Bytes | Description |
|---|---|---|
| group_type | 1 B/group | Dispatch key |
| route_priority | 1 B/group | Routing order |
| tolerance | 4 B/group | Matching tolerance |
| preferred_layer | 3 B/group | Target metal layer |
| status | 1 B/group | pending/routing/routed/failed |

**Net membership** (variable-length, flattened):

| Column | Bytes | Description |
|---|---|---|
| net_range_start | 4 B/group | Offset into net_pool |
| net_count | 1 B/group | Number of nets (max 255) |
| net_pool | 4 B/net | All net IDs, flat |

**Cold fields** (touched only during setup/reporting):
names, thermal_tolerance, coupling_tolerance, shield_net, force_net, sense_net, centroid_pattern.

Hot working set for 200 groups: 2.6 KB (41 cache lines) — L1 resident during dispatch.

---

## Validation Rules

| Group type | Required nets | Additional |
|---|---|---|
| differential | exactly 2 | — |
| matched | ≥ 2 | — |
| shielded | exactly 1 | — |
| kelvin | exactly 2 | force_net != null AND sense_net != null |
| resistor_matched | ≥ 2 | — |
| capacitor_array | ≥ 2 | — |
| any | — | 0.0 ≤ tolerance ≤ 1.0 |

Errors returned: `InvalidNetCount`, `InvalidTolerance`, `DeviceTypeMismatch`, `MissingKelvinNets`, `GroupTableFull`.
