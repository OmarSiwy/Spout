# Placement Optimization Algorithm

The Spout placer is a **multi-phase Simulated Annealing** engine operating on continuous floating-point coordinates. This document describes every component of the algorithm in full detail: data structures, temperature schedule, move types, cost function evaluation, and acceptance criterion.

---

## Algorithm Overview

```
Input:  N devices, P pins, M nets, K constraints
Output: device_positions [][2]f32  (modified in place)

1. Greedy Initial Placement
   – Place devices in a single row with 1 µm gaps
   – Centre the row within the layout canvas
   – If use_template_bounds: scatter uniformly within template area

2. Pin Position Synchronization
   – For each pin i: position = device_pos[pin_info[i].device]
                              + transform(offset, orientation)

3. RUDY Grid Initialization
   – tile_size = 10 µm, metal_pitch = 0.5 µm
   – rows = ceil(layout_height / tile_size)
   – cols = ceil(layout_width  / tile_size)
   – capacity[tile] = 2 × tile_size / metal_pitch = 40 wire-length units
   – demand: full recomputation from pin positions + net adjacency

4. Cost Function Full Computation  (16 terms)

5. SA Main Loop
   while T > T_min:
     alpha = computeAlpha(T, T₀)
     M_level = max(1, κ × N)           // κ = 20 by default
     accepted_this_level = 0
     for i in 0..M_level:
       accepted = runOneMove(...)
       if accepted: accepted_this_level++
     acceptance_rate = accepted_this_level / M_level
     if acceptance_rate < 0.02 and reheat_count < max_reheats:
       T *= 3.0                         // reheat
       reheat_count++
     T *= alpha

6. Final Pass: recompute pins, RUDY, full cost

7. Post-SA: dummy count estimate, guard ring validation
```

---

## Phase 1: Greedy Initial Placement

Before SA begins, the `runSa` function places all devices in a horizontal row:

```zig
var cursor_x: f32 = 0.0;
for (0..num_devices) |di| {
    const dw = device_dimensions[di][0] or 2.0;
    const dh = device_dimensions[di][1] or 2.0;
    device_positions[di][0] = cursor_x + dw * 0.5;  // centre
    device_positions[di][1] = dh * 0.5;
    cursor_x += dw + 1.0;  // 1 µm spacing gap
}
// Shift to centre within canvas:
const offset_x = max(0, (layout_width - total_width) * 0.5);
const offset_y = max(0, (layout_height - max_height) * 0.5);
```

When `config.use_template_bounds = true`, devices are instead randomly scattered within the template bounding box using the PRNG.

**Rationale**: Starting from a compact, non-overlapping row minimizes the initial overlap cost and gives the SA a feasible starting point. Random initialization often creates configurations with so much overlap that the SA spends all its high-temperature budget on deoverlapping rather than exploring the constraint-satisfaction landscape.

---

## Phase 2: RUDY Congestion Grid

The RUDY (Rectangular Uniform wire DensitY) grid estimates routing demand before any routing is performed. It works by "splatting" each net's bounding box onto the tile grid.

### Grid Dimensions

```zig
cols = max(1, ceil(layout_width  / tile_size))  // e.g. 100/10 = 10 columns
rows = max(1, ceil(layout_height / tile_size))  // e.g. 50/10  = 5 rows
capacity[tile] = 2.0 × tile_size / metal_pitch  // = 40 per tile at 0.5 µm pitch
```

The factor of 2.0 assumes two routing layers (one horizontal, one vertical) are available.

### RUDY Density Formula

For each net with bounding box (x_min, x_max, y_min, y_max):

```
w_n = x_max - x_min
h_n = y_max - y_min
area_n = max(w_n, 1e-6) × max(h_n, 1e-6)
RUDY_density = (w_n + h_n) / area_n        // = HPWL / area
```

Each tile that overlaps the net bounding box receives:
```
demand[tile] += RUDY_density × overlap_area(tile, net_bbox)
```

### Incremental Update

On each SA move, only the nets touching the moved device(s) are updated:
```
updateIncremental(affected_nets, old_pin_positions, new_pin_positions, adj)
```
This subtracts the old contribution and adds the new contribution. The affected nets are computed from the `device_nets` map (built once before the SA loop).

### Overflow Metric

```
total_overflow = Σ_tiles max(0, demand[tile] - capacity[tile])
```

This is the `rudy_overflow` term in the cost function. Weight `w_rudy = 0.3`.

---

## Phase 3: SA Temperature Schedule

The Spout SA uses a **two-level κ·N schedule** with a three-phase cooling rate:

### Three-Phase Cooling

```zig
fn computeAlpha(temperature: f32, initial_temp: f32) f32 {
    return if (temperature > 0.3 * initial_temp)
        0.80   // Phase 1: fast drop through hot, useless region
    else if (temperature > 0.05 * initial_temp)
        0.97   // Phase 2: slow refinement in productive zone
    else
        0.80;  // Phase 3: fast freeze to minimum
}
```

| Phase | Temperature Range | α | Purpose |
|---|---|---|---|
| 1 | T > 30% T₀ | 0.80 | Fast descent through high-entropy region |
| 2 | 5% T₀ < T ≤ 30% T₀ | 0.97 | Fine-grained exploration and convergence |
| 3 | T ≤ 5% T₀ | 0.80 | Quick freeze — no meaningful improvement expected |

### κ·N Moves Per Temperature Level

Each temperature level executes exactly `κ × N` moves, where:
- `κ = 20.0` (default) — moves per device per temperature level
- `N` = number of devices

For a 100-device circuit: 2000 moves/level. This ensures the SA sees the same number of moves regardless of circuit size, scaling correctly as N increases.

### Legacy Flat Loop

When `kappa = 0`, the SA falls back to a flat loop over `max_iterations` total moves with `temperature *= cooling_rate` after each move. This preserves backward compatibility with C callers that set `max_iterations` directly.

### Adaptive Perturbation Range

The translation step size ρ scales linearly with temperature:

```zig
fn computeRho(T, T₀, layout_width, layout_height, override) f32 {
    if (override > 0.0) return override;
    rho_max = max(layout_width, layout_height);  // full canvas diagonal
    t_ref   = 0.3 × T₀;
    return rho_max × min(1.0, T / t_ref);
}
```

At high temperature (T ≥ t_ref): ρ = ρ_max (moves can reach any point in the canvas)
At low temperature: ρ shrinks linearly to near-zero (local refinement only)

### Reheating

After each temperature level, the acceptance rate is measured:
```
r = accepted_this_level / M_level
if r < 0.02 and reheat_count < max_reheats:
    T *= 3.0
    reheat_count++
```

If fewer than 2% of moves were accepted, the system is thermally frozen. Tripling the temperature injects energy to escape local minima. A maximum of 5 reheats (`max_reheats = 5`) is allowed per run.

---

## Phase 4: Move Types

### Move Type Selection

```zig
const roll = random.float(f32);   // uniform [0, 1)
var threshold: f32 = 0.0;

threshold += p_orientation_flip;  // default 0.05
if roll < threshold → orientation_flip

threshold += p_group_translate;   // default 0.0
if roll < threshold and centroid_groups.len > 0 → group_translate

threshold += p_swap;              // default 0.65
if roll < threshold and N >= 2 → swap

→ translate  (remainder)
```

Effective default probabilities: orientation_flip=5%, swap=61.75%, translate=33.25%

### Translate Move

```
1. Pick random device dev ∈ [0, N)
2. Save old position and pin positions
3. dx = (random.float - 0.5) × 2 × ρ(T)
   dy = (random.float - 0.5) × 2 × ρ(T)
4. new_pos = clamp(old_pos + (dx, dy), [0, layout_width] × [0, layout_height])
5. If use_template_bounds and new_pos outside template_bbox → reject immediately
6. updatePinPositions(dev, new_pos)
7. rudy_grid.updateIncremental(device_nets[dev], old_pins, new_pins)
8. delta = computeDeltaCost(dev, ...)
9. Metropolis accept/reject
10. If rejected: restore old position and pin positions, revert RUDY
```

### Swap Move

```
1. Pick two distinct random devices dev_i, dev_j
2. Check for symmetry constraint between them:
   if symmetry constraint exists → mirror_swap branch
3. Save positions, pin positions
4. Exchange positions: pos[i] ↔ pos[j]
5. Recompute pins for both devices
6. Affected nets = union(nets[dev_i], nets[dev_j]) — deduplicated
7. RUDY update for union net set
8. Compute delta
9. Metropolis accept/reject
```

### Mirror Swap

Triggered when a symmetry constraint links `dev_i` and `dev_j`:

```
For .symmetry constraint (X-axis mirror about axis_x):
  new_pos_i[0] = 2×axis_x - old_pos_j[0]   // mirror j's x
  new_pos_i[1] = old_pos_j[1]               // take j's y
  new_pos_j[0] = 2×axis_x - old_pos_i[0]   // mirror i's x
  new_pos_j[1] = old_pos_i[1]               // take i's y

For .symmetry_y constraint (Y-axis mirror about axis_y):
  new_pos_i[0] = old_pos_j[0]
  new_pos_i[1] = 2×axis_y - old_pos_j[1]   // mirror j's y
  new_pos_j[0] = old_pos_i[0]
  new_pos_j[1] = 2×axis_y - old_pos_i[1]   // mirror i's y
```

This preserves the mirror relationship during exploration and helps the SA converge to symmetric configurations faster than random perturbation alone.

### Orientation Flip Move

```
1. Pick random device dev
2. Save old orientation and pin positions
3. Pick new orientation uniformly from {N, S, FN, FS, E, W, FE, FW}
4. Update orientations[dev] = new_orientation
5. Recompute pin positions for dev (transform changes offsets)
6. Delta cost computation includes orientation mismatch recomputation
7. Metropolis accept/reject
```

### Group Translate Move

When `centroid_groups` is non-empty and `p_group_translate > 0`:

```
1. Pick random centroid group
2. Pick group A or group B
3. Compute (dx, dy) = ρ(T) × random unit vector
4. Apply same (dx, dy) to ALL devices in the chosen group
5. Recompute pins for all moved devices
6. Affected nets = union of all nets for all devices in the group
7. Delta cost, Metropolis accept/reject
```

This move shifts the entire group as a rigid body, allowing the SA to explore different relative positions between group A and group B without changing the internal arrangement of either group.

---

## Phase 5: Cost Function

The cost function is a weighted sum of 16 terms:

```
cost = w_hpwl           × (Σ_nets HPWL(n)) / num_nets
     + w_area           × bounding_box_area
     + w_symmetry       × Σ_sym_constraints symmetry_penalty
     + w_matching       × Σ_match_constraints matching_penalty
     + w_proximity      × Σ_prox_constraints proximity_penalty
     + w_isolation      × Σ_isol_constraints isolation_penalty
     + w_rudy           × total_rudy_overflow
     + w_overlap        × Σ_device_pairs overlap_area
     + w_thermal        × Σ_match thermal_mismatch
     + w_orientation    × Σ_orient_match orientation_mismatch
     + w_lde            × Σ_match (ΔSA² + ΔSB²)
     + w_common_centroid× Σ_groups centroid_distance²
     + w_parasitic      × Σ_match routing_length_imbalance²
     + w_interdigitation× Σ_groups interdigitation_cost
     + w_edge_penalty   × Σ_match edge_exposure_asymmetry²
     + w_wpe            × Σ_match well_edge_distance_imbalance²
```

### HPWL Computation

Half-perimeter bounding box for each net:
```
HPWL(n) = (max_x_pins - min_x_pins) + (max_y_pins - min_y_pins)
```

Power nets are excluded from HPWL (supply nets have very low routing resistance and their wirelength does not affect timing). The total is normalized by `num_nets` so the HPWL term's absolute value is independent of circuit size.

**Incremental update**: only nets touching the moved device are recomputed. The cached `hpwl_sum` is updated by subtraction of old and addition of new per-net HPWL values.

### Overlap Computation

Axis-Aligned Bounding Box (AABB) overlap for all device pairs:

```
For each pair (i, j) with i < j:
  overlap_x = max(0, min(x_i + w_i/2, x_j + w_j/2) - max(x_i - w_i/2, x_j - w_j/2))
  overlap_y = max(0, min(y_i + h_i/2, y_j + h_j/2) - max(y_i - h_i/2, y_j - h_j/2))
  cost += overlap_x × overlap_y
```

O(N²) but circuit sizes are 10–500 devices so this is at most 125,000 pair checks — negligible per SA iteration.

The very high weight (`w_overlap = 100.0`) ensures overlap dominates cost until all overlaps are resolved.

---

## Phase 6: Metropolis Acceptance Criterion

The standard Metropolis criterion with Boltzmann probability:

```zig
const delta = result.delta;  // new_cost - old_cost

if (delta < 0.0) {
    // Improvement: always accept
    accept = true;
} else {
    // Degradation: accept with probability exp(-delta / T)
    const prob = @exp(-delta / temperature);
    accept = (random.float(f32) < prob);
}

if (accept) {
    cost_fn.acceptDelta(...)  // commit all 16 sub-costs
} else {
    // Revert: restore device positions, pin positions, RUDY demand
}
```

At high temperature T, `exp(-delta/T) ≈ 1` and even large degradations are accepted. At low temperature, only very small degradations pass. This provides the SA's thermal escape mechanism.

---

## Force-Directed Visualization (Before/After SA)

```svg
<svg viewBox="0 0 860 520" xmlns="http://www.w3.org/2000/svg" font-family="'Inter', 'Segoe UI', sans-serif">
  <title>SA Placement — Before and After</title>
  <rect width="860" height="520" fill="#060C18"/>

  <text x="30" y="26" fill="#00C4E8" font-size="14" font-weight="bold">Simulated Annealing Placement — Before and After</text>

  <!-- LEFT panel: initial (greedy row) placement -->
  <rect x="20" y="40" width="380" height="340" fill="#09111F" stroke="#14263E" stroke-width="1" rx="4"/>
  <text x="210" y="64" fill="#3E5E80" font-size="12" text-anchor="middle">Initial Placement (High T)</text>

  <!-- Grid for left panel -->
  <defs>
    <pattern id="g2" width="30" height="30" patternUnits="userSpaceOnUse">
      <path d="M 30 0 L 0 0 0 30" fill="none" stroke="#0D1E35" stroke-width="0.4"/>
    </pattern>
    <clipPath id="leftClip">
      <rect x="20" y="40" width="380" height="340"/>
    </clipPath>
    <clipPath id="rightClip">
      <rect x="450" y="40" width="380" height="340"/>
    </clipPath>
  </defs>
  <rect x="20" y="40" width="380" height="340" fill="url(#g2)" rx="4"/>

  <!-- Devices in initial row (left panel) -->
  <!-- All in a row, big spacing -->
  <rect x="35" y="180" width="50" height="40" fill="#09111F" stroke="#1E88E5" stroke-width="1.5" rx="4"/>
  <text x="60" y="206" fill="#B8D0E8" font-size="10" text-anchor="middle">M1</text>
  <circle cx="60" cy="180" r="3" fill="#00C4E8"/>

  <rect x="100" y="180" width="50" height="40" fill="#09111F" stroke="#1E88E5" stroke-width="1.5" rx="4"/>
  <text x="125" y="206" fill="#B8D0E8" font-size="10" text-anchor="middle">M2</text>
  <circle cx="125" cy="180" r="3" fill="#00C4E8"/>

  <rect x="165" y="180" width="50" height="40" fill="#09111F" stroke="#EF5350" stroke-width="1.5" rx="4"/>
  <text x="190" y="206" fill="#B8D0E8" font-size="10" text-anchor="middle">M3</text>
  <circle cx="190" cy="180" r="3" fill="#00C4E8"/>

  <rect x="230" y="180" width="50" height="40" fill="#09111F" stroke="#EF5350" stroke-width="1.5" rx="4"/>
  <text x="255" y="206" fill="#B8D0E8" font-size="10" text-anchor="middle">M4</text>
  <circle cx="255" cy="180" r="3" fill="#00C4E8"/>

  <rect x="295" y="180" width="50" height="40" fill="#09111F" stroke="#43A047" stroke-width="1.5" rx="4"/>
  <text x="320" y="206" fill="#B8D0E8" font-size="10" text-anchor="middle">R1</text>
  <circle cx="320" cy="180" r="3" fill="#00C4E8"/>

  <!-- Spring lines (net connections, long → high tension) left panel -->
  <!-- Net 0: M1-M2 (short spring, close) -->
  <line x1="60" y1="180" x2="125" y2="180" stroke="#00C4E8" stroke-width="1.5" opacity="0.7"/>
  <text x="92" y="174" fill="#00C4E8" font-size="8" text-anchor="middle">VIN+</text>

  <!-- Net 1: M3-M4 (short spring) -->
  <line x1="190" y1="180" x2="255" y2="180" stroke="#EF5350" stroke-width="1.5" opacity="0.7"/>
  <text x="222" y="174" fill="#EF5350" font-size="8" text-anchor="middle">VIN-</text>

  <!-- Net 2: M1 drain to R1 (long, stretched spring) -->
  <path d="M 85 190 Q 200 130 320 190" fill="none" stroke="#FB8C00" stroke-width="2" stroke-dasharray="3,2" opacity="0.8"/>
  <text x="200" y="126" fill="#FB8C00" font-size="8" text-anchor="middle">VOUT (long!)</text>

  <!-- Net 3: M3 to R1 (also long) -->
  <path d="M 215 190 Q 265 250 320 200" fill="none" stroke="#43A047" stroke-width="2" stroke-dasharray="3,2" opacity="0.8"/>

  <!-- Force arrows on left panel (large, showing tension) -->
  <!-- M1 being pulled right -->
  <polygon points="95,172 103,175 95,178" fill="#FB8C00"/>
  <line x1="60" y1="175" x2="93" y2="175" stroke="#FB8C00" stroke-width="1.5"/>
  <!-- M3 being pulled right -->
  <polygon points="270,172 278,175 270,178" fill="#43A047"/>
  <line x1="215" y1="175" x2="268" y2="175" stroke="#43A047" stroke-width="1.5"/>
  <!-- R1 being pulled left -->
  <polygon points="308,172 300,175 308,178" fill="#FB8C00"/>
  <line x1="340" y1="175" x2="311" y2="175" stroke="#FB8C00" stroke-width="1.5"/>

  <text x="210" y="355" fill="#3E5E80" font-size="10" text-anchor="middle">HPWL = 320 µm (high)</text>
  <text x="210" y="370" fill="#3E5E80" font-size="10" text-anchor="middle">T = 1000.0 → moves = 100/level</text>

  <!-- Arrow between panels -->
  <text x="430" y="218" fill="#00C4E8" font-size="26" text-anchor="middle">→</text>
  <text x="430" y="238" fill="#3E5E80" font-size="9" text-anchor="middle">SA</text>
  <text x="430" y="251" fill="#3E5E80" font-size="9" text-anchor="middle">converges</text>

  <!-- RIGHT panel: optimized placement -->
  <rect x="450" y="40" width="380" height="340" fill="#09111F" stroke="#14263E" stroke-width="1" rx="4"/>
  <text x="640" y="64" fill="#43A047" font-size="12" text-anchor="middle">Converged Placement (Low T)</text>
  <rect x="450" y="40" width="380" height="340" fill="url(#g2)" rx="4"/>

  <!-- Optimized device positions (clustered by net, symmetric pair together) -->
  <!-- M1 and M2 (NMOS diff pair) near center-left, symmetric -->
  <rect x="530" y="130" width="50" height="40" fill="#09111F" stroke="#1E88E5" stroke-width="2" rx="4"/>
  <text x="555" y="156" fill="#B8D0E8" font-size="10" text-anchor="middle">M1</text>
  <circle cx="555" cy="130" r="3" fill="#00C4E8"/>

  <rect x="650" y="130" width="50" height="40" fill="#09111F" stroke="#1E88E5" stroke-width="2" rx="4"/>
  <text x="675" y="156" fill="#B8D0E8" font-size="10" text-anchor="middle">M2</text>
  <circle cx="675" cy="130" r="3" fill="#00C4E8"/>

  <!-- M3 and M4 (PMOS pair) symmetrically above -->
  <rect x="530" y="220" width="50" height="40" fill="#09111F" stroke="#EF5350" stroke-width="2" rx="4"/>
  <text x="555" y="246" fill="#B8D0E8" font-size="10" text-anchor="middle">M3</text>
  <circle cx="555" cy="260" r="3" fill="#00C4E8"/>

  <rect x="650" y="220" width="50" height="40" fill="#09111F" stroke="#EF5350" stroke-width="2" rx="4"/>
  <text x="675" y="246" fill="#B8D0E8" font-size="10" text-anchor="middle">M4</text>
  <circle cx="675" cy="260" r="3" fill="#00C4E8"/>

  <!-- R1 between the pairs (on shared net) -->
  <rect x="590" y="165" width="40" height="70" fill="#09111F" stroke="#43A047" stroke-width="2" rx="4"/>
  <text x="610" y="207" fill="#B8D0E8" font-size="10" text-anchor="middle">R1</text>
  <circle cx="610" cy="165" r="3" fill="#00C4E8"/>
  <circle cx="610" cy="235" r="3" fill="#00C4E8"/>

  <!-- Net connections (short, relaxed) right panel -->
  <line x1="555" y1="130" x2="610" y2="165" stroke="#FB8C00" stroke-width="1.5" opacity="0.7"/>
  <line x1="675" y1="130" x2="610" y2="165" stroke="#43A047" stroke-width="1.5" opacity="0.7"/>
  <line x1="555" y1="260" x2="610" y2="235" stroke="#FB8C00" stroke-width="1.5" opacity="0.7"/>
  <line x1="675" y1="260" x2="610" y2="235" stroke="#43A047" stroke-width="1.5" opacity="0.7"/>

  <!-- Symmetry axis on right panel -->
  <line x1="615" y1="55" x2="615" y2="360" stroke="#00C4E8" stroke-width="1.5" stroke-dasharray="6,3" opacity="0.7"/>
  <text x="618" y="72" fill="#00C4E8" font-size="9">Sym axis</text>

  <!-- Small force arrows (relaxed, pointing to R1) right panel -->
  <polygon points="601,148 593,151 601,154" fill="#FB8C00" opacity="0.5"/>
  <line x1="555" y1="151" x2="599" y2="151" stroke="#FB8C00" stroke-width="0.8" opacity="0.5"/>
  <polygon points="624,148 632,151 624,154" fill="#43A047" opacity="0.5"/>
  <line x1="675" y1="151" x2="626" y2="151" stroke="#43A047" stroke-width="0.8" opacity="0.5"/>

  <text x="640" y="355" fill="#43A047" font-size="10" text-anchor="middle">HPWL = 85 µm (low)</text>
  <text x="640" y="370" fill="#3E5E80" font-size="10" text-anchor="middle">T = 0.01 → moves = local</text>

  <!-- Bottom legend -->
  <rect x="20" y="400" width="820" height="100" fill="#09111F" stroke="#14263E" stroke-width="1" rx="6"/>
  <text x="430" y="422" fill="#00C4E8" font-size="12" font-weight="bold" text-anchor="middle">SA Cost Convergence Properties</text>
  <text x="40" y="444" fill="#B8D0E8" font-size="11">Phase 1 (T &gt; 300): α=0.80 — Device can jump anywhere. High-cost moves accepted ~50% of time.</text>
  <text x="40" y="460" fill="#B8D0E8" font-size="11">Phase 2 (15&lt;T≤300): α=0.97 — Slow exploration of productive space. Most accepted moves improve cost.</text>
  <text x="40" y="476" fill="#B8D0E8" font-size="11">Phase 3 (T≤15):  α=0.80 — Fast freeze. Only near-zero degradations accepted (&lt;1% of moves).</text>
  <text x="40" y="492" fill="#3E5E80" font-size="10">Reheating: if acceptance &lt; 2% at any level, T ×= 3.0 (up to 5× total). Prevents premature convergence in local minima.</text>
</svg>
```

---

## DeltaResult: Incremental Cost Cache

The `DeltaResult` struct carries the new value of every cost sub-term after a proposed move. This allows the SA to commit a move in O(1) by copying the cached values into `CostFunction`:

```zig
pub const DeltaResult = struct {
    new_total:           f32,
    delta:               f32,   // = new_total - old_total
    new_hpwl_sum:        f32,
    new_area:            f32,
    new_sym:             f32,
    new_match:           f32,
    new_prox:            f32,
    new_iso:             f32,
    new_rudy:            f32,
    new_overlap:         f32,
    new_thermal:         f32,
    new_lde:             f32,
    new_orientation:     f32,
    new_centroid:        f32,
    new_parasitic:       f32,
    new_interdigitation: f32,
    new_edge_penalty:    f32,
    new_wpe:             f32,
};
```

On acceptance: `cost_fn.acceptDelta(result)` copies all fields.
On rejection: positions and pin positions are restored from saved buffers; RUDY demand is reverted with `updateIncremental`.

There is also a fast path `acceptTotal(new_total)` that only updates the total, used when sub-cost breakdown is not needed externally.

---

## Hierarchical Macro Placement

The SA engine supports a hierarchical mode for circuits with large repeated subcells (macros):

1. **Phase 1**: SA on individual unit cells within each macro instance.
2. **Phase 2**: SA on macro instances as rigid bodies (`macro_translate` and `macro_transform` moves).
3. **Phase 1b re-optimization**: If `hpwl_ratio_phase1b > 0` and the unit-cell HPWL is more than `hpwl_ratio_phase1b` fraction of the top-level HPWL after phase 2, run unit-cell SA again with the final macro positions locked.

Macro instances are detected by `src/macro/lib.zig` (the MacroArrays type) and passed into `runSa` as implicit context through the `SpoutContext`.

The `macro_translate` and `macro_transform` moves are handled inside `runSaHierarchical` (referenced in sa.zig but not the primary `runOneMove` path). These moves shift or affine-transform all constituent devices of a macro instance together.

---

## Performance Analysis

For analog-scale circuits (N = 10–500 devices):

| Operation | Complexity | Notes |
|---|---|---|
| HPWL (incremental) | O(pins_per_net) | Only affected nets recomputed |
| Area | O(N) | Full recompute each time |
| Symmetry | O(K) | K = constraint count, typically < 50 |
| Matching | O(K) | Same |
| Overlap | O(N²) | At N=500: 125K pair checks |
| RUDY update | O(affected_tiles) | Proportional to bounding box tiles |
| LDE | O(K×N) | K pairs × N neighbor scan |
| Common-centroid | O(G×M) | G = groups, M = devices per group |
| Total per move | O(N²) dominated | By overlap term |

The SA loop runs `κ×N×T_levels` total moves. For κ=20, N=100, T_levels≈500 (T from 1000 to 0.01 at α=0.97): 1,000,000 moves. At O(N²)=10,000 operations per move: 10 billion operations. At 1 GFlop/s effective throughput: ~10 seconds. In practice much faster due to cache locality and simple arithmetic.
