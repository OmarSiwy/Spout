# Placer Constraints

Every constraint in the Spout placer is a pair `(kind, dev_a, dev_b)` plus up to three scalar parameters (`axis_x`, `axis_y`, `param`). Constraints are evaluated inside the SA cost function on every move. They do not enforce hard boundaries (except template bounds) — they add penalty energy that the SA minimizes.

---

## Constraint Struct

```zig
pub const Constraint = struct {
    kind:   ConstraintType,   // determines which cost term is evaluated
    dev_a:  u32,              // index of device A in DeviceArrays
    dev_b:  u32,              // index of device B in DeviceArrays
    axis_x: f32 = 0.0,        // for symmetry: x-coordinate of vertical axis
    axis_y: f32 = 0.0,        // for symmetry_y: y-coordinate of horizontal axis
    param:  f32 = 0.0,        // for proximity: max_dist; for isolation: min_dist
};
```

---

## 1. Symmetry (`kind = .symmetry`, value 0)

### Electrical Meaning

A symmetry constraint states that two devices are a **matched pair** that must be mirror images about a vertical axis. This is mandatory for differential pairs, current mirrors, and any circuit topology where two branches must see identical physical environments.

Without symmetry enforcement, gradients in doping, temperature, and oxide thickness will create systematic Vth offsets. The Pelgrom mismatch model shows that random mismatch decreases as `1/√(W·L)` but systematic gradient mismatch depends entirely on the centroid separation of the matched devices.

### Encoding

```zig
.{ .kind = .symmetry, .dev_a = 0, .dev_b = 1, .axis_x = 5.0 }
```

This constraint says: device 0 and device 1 must be mirrored about the vertical line x = 5.0 µm.

For a perfect placement:
- `x_a + x_b = 2 × axis_x` (centroids equidistant from axis)
- `y_a = y_b` (same row — equal Y positions)

### Cost Term (in `computeSymmetry`)

Two norm options controlled by `CostWeights.symmetry_norm`:

**L2 norm (default)**:
```
cost += (x_a + x_b - 2·axis_x)² + (y_a - y_b)²
```

**L1 norm**:
```
cost += |x_a + x_b - 2·axis_x| + |y_a - y_b|
```

L2 creates steeper barriers near perfect symmetry, discouraging the SA from moving away from a symmetric configuration. L1 has a linear rise that allows the SA to explore across violations more freely during high-temperature phases.

**Default weight**: `w_symmetry = 2.0`

### Effect on SA

The `mirror_swap` move in `sa.zig` detects symmetry constraints and performs a swap that simultaneously moves both devices to maintain the mirror relationship. When device A moves by (+Δ, 0), device B is moved to (-Δ, 0) relative to the axis. This allows the SA to explore while keeping the pair correlated.

---

## 2. Y-Axis Symmetry (`kind = .symmetry_y`, value 4)

### Electrical Meaning

Same as x-axis symmetry but mirrored about a **horizontal** axis. Required for vertically-stacked matched pairs (source-degenerated differential pairs, stacked current mirrors).

### Encoding

```zig
.{ .kind = .symmetry_y, .dev_a = 0, .dev_b = 1, .axis_y = 8.0 }
```

Devices must be mirrored about the horizontal line y = 8.0 µm.

For a perfect placement:
- `x_a = x_b` (same column)
- `y_a + y_b = 2 × axis_y` (equidistant from horizontal axis)

### Cost Term

**L2 norm**:
```
cost += (x_a - x_b)² + (y_a + y_b - 2·axis_y)²
```

**L1 norm**:
```
cost += |x_a - x_b| + |y_a + y_b - 2·axis_y|
```

---

## 3. Matching (`kind = .matching`, value 1)

### Electrical Meaning

A matching constraint states that two devices are a matched pair and should be placed at a distance that minimizes LDE (Local Layout Effect) differences while not being so far apart that gradient mismatch dominates. The placer enforces a **minimum separation distance** based on device dimensions, creating a parabolic potential well.

The matching constraint also acts as the "selector" for multiple other cost terms that piggyback on it:
- LDE equalization (SA/SB computation)
- Thermal mismatch
- Parasitic routing balance
- Edge penalty
- WPE mismatch

### Encoding

```zig
.{ .kind = .matching, .dev_a = 0, .dev_b = 1 }
```

No axis or param required. The minimum separation (`min_sep`) is derived from the device dimensions:

```zig
const half_a = @max(dims[dev_a][0], dims[dev_a][1]) * 0.5;
const half_b = @max(dims[dev_b][0], dims[dev_b][1]) * 0.5;
const min_sep = half_a + half_b;  // or default_min_spacing = 2.0 µm if dims are zero
```

### Cost Term (in `computeMatching`)

```
dist = √((x_a - x_b)² + (y_a - y_b)²)
cost += max(0, dist - min_sep)²
```

This is a parabolic well that is zero when the devices are closer than `min_sep` and grows quadratically as they move apart. It drives matched devices close together (to minimize gradient exposure) while the minimum-separation floor prevents them from overlapping.

**Default weight**: `w_matching = 1.5`

---

## 4. Proximity (`kind = .proximity`, value 2)

### Electrical Meaning

A proximity constraint says two devices must be within a maximum distance of each other. Use cases:
- Decoupling capacitor must be close to the circuit it decouples.
- Bias device should be near the mirror it serves (to minimize routing resistance).
- Body-tied transistors must be near their well tap.

### Encoding

```zig
.{ .kind = .proximity, .dev_a = 0, .dev_b = 1, .param = 20.0 }
```

`param = 20.0` µm is the maximum allowed centre-to-centre distance.

### Cost Term (in `computeProximity`)

```
dist = √((x_a - x_b)² + (y_a - y_b)²)
excess = max(0, dist - param)
cost += excess²
```

Zero cost when devices are within `param` µm. Quadratic penalty beyond that.

**Default weight**: `w_proximity = 1.0`

---

## 5. Isolation (`kind = .isolation`, value 3)

### Electrical Meaning

An isolation constraint says two devices must be at least a minimum distance apart (edge-to-edge). Use cases:
- Analog block separated from digital switching noise.
- Substrate noise isolation between sensitive amplifier and digital logic.
- Guard ring enforcement (kept far from noise sources).

RESEARCH_TECHNIQUES.md Section 19 documents substrate noise isolation requirements: a guard ring provides ~9 dB, deep N-well provides 20+ dB, but sufficient physical separation is a precondition.

### Encoding

```zig
.{ .kind = .isolation, .dev_a = 2, .dev_b = 5, .param = 50.0 }
```

`param = 50.0` µm is the minimum required edge-to-edge distance.

### Cost Term (in `computeIsolation`)

```
dist = √((x_a - x_b)² + (y_a - y_b)²)
half_a = max(dims[dev_a][0], dims[dev_a][1]) / 2
half_b = max(dims[dev_b][0], dims[dev_b][1]) / 2
edge_dist = dist - half_a - half_b
violation = max(0, param - edge_dist)
cost += violation²
```

The half-dimension subtraction converts centre-to-centre distance to edge-to-edge distance.

**Default weight**: `w_isolation = 1.0`

---

## 6. Orientation Match (`kind = .orientation_match`, value 5)

### Electrical Meaning

Silicon crystal anisotropy and tilted ion implant angles cause ~5% systematic error when matched devices have different orientations. NMOS devices, for example, have higher hole mobility along `<110>` than `<100>`. Two matched transistors at 90° to each other will have different mobility even if identically sized.

### Encoding

```zig
.{ .kind = .orientation_match, .dev_a = 0, .dev_b = 1 }
```

### Cost Term (in `computeOrientationMismatch`)

Binary penalty:
```zig
if (orientations[dev_a] != orientations[dev_b]) sum += 1.0;
```

This creates a discrete incentive: the SA orientation flip move will resolve mismatches.

**Default weight**: `w_orientation = 2.0`

### Orientation Enum

```zig
pub const Orientation = enum(u8) {
    N  = 0,  // north — no transform (default)
    S  = 1,  // south — 180° rotation
    FN = 2,  // flip north — mirror about Y axis
    FS = 3,  // flip south — mirror Y + 180°
    E  = 4,  // east — 90° clockwise
    W  = 5,  // west — 90° counter-clockwise
    FE = 6,  // flip + 90° CW
    FW = 7,  // flip + 90° CCW
};
```

Pin offset transforms per orientation (base offset `(ox, oy)` → transformed):
```
N:  ( ox,  oy)    S:  (-ox, -oy)
FN: (-ox,  oy)    FS: ( ox, -oy)
E:  ( oy, -ox)    W:  (-oy,  ox)
FE: ( oy,  ox)    FW: (-oy, -ox)
```

---

## 7. Common-Centroid (`kind = .common_centroid`, value 6)

### Electrical Meaning

Common-centroid placement is the most powerful technique for cancelling systematic gradients. If two device groups have coincident centroids, any linear gradient in doping, temperature, or stress contributes **zero** systematic mismatch.

The mathematical basis (from the six-component mismatch model):
```
P_A - P_B = m × [g₁₀·(x̄_A - x̄_B) + g₀₁·(ȳ_A - ȳ_B)]
```
where `g₁₀`, `g₀₁` are the X and Y gradient coefficients of any process parameter. When `x̄_A = x̄_B` and `ȳ_A = ȳ_B` (centroids coincide), the mismatch from linear gradients vanishes regardless of the gradient magnitude.

The classic ABBA pattern for two 2-finger devices:
- Group A: fingers at x=1, x=4
- Group B: fingers at x=2, x=3
- Centroid A: (1+4)/2 = 2.5; Centroid B: (2+3)/2 = 2.5 ✓

### Encoding

Common-centroid uses a **sidecar array** because it constrains groups, not pairs:

```zig
pub const CentroidGroup = struct {
    group_a: []const u32,  // device indices in group A
    group_b: []const u32,  // device indices in group B
};
```

The `SaExtendedInput` carries `centroid_groups: []const CentroidGroup`. The constraint kind `common_centroid` in the Constraint struct encodes the sidecar index in `param`.

### Cost Term (in `computeCommonCentroid`)

```
centroid_Ax = (1/|A|) × Σ_{i∈A} x_i
centroid_Ay = (1/|A|) × Σ_{i∈A} y_i
centroid_Bx = (1/|B|) × Σ_{j∈B} x_j
centroid_By = (1/|B|) × Σ_{j∈B} y_j

cost += (centroid_Ax - centroid_Bx)² + (centroid_Ay - centroid_By)²
```

**Default weight**: `w_common_centroid = 2.0`

### Group Translate Move

When `p_group_translate > 0` in `SaConfig`, the SA selects a `group_translate` move that shifts all devices in one half of a centroid group by the same (dx, dy), preserving internal group layout while exploring different relative positions.

---

## 8. Interdigitation (`kind = .interdigitation`, value 7)

### Electrical Meaning

Interdigitation places unit cells of two matched devices alternating along one axis: A₁B₁A₂B₂... This cancels first-order gradients along that axis because the X-centroid of both groups is equal.

For n fingers per device at positions x_k = k·d:
- Symmetric interdigitation: A at k=0,2,4...; B at k=1,3,5...
- Sum_A = 0+2+4+... = n(n-1)/2 × 2; Sum_B = 1+3+5+... = same → centroids match

Interdigitation is the 1D gradient cancellation technique, positioned between simple proximity matching and full 2D common-centroid.

### Encoding

Reuses the `CentroidGroup` sidecar:
- `group_a`: unit-cell device indices for device A
- `group_b`: unit-cell device indices for device B

### Cost Term (in `computeInterdigitation`)

Two components:
1. **Centroid imbalance** (primary): `(centroid_Ax - centroid_Bx)²`
2. **Adjacency violations** (secondary): count of same-group adjacent pairs when sorted by X position; drives ABABAB pattern rather than AAABBB

**Default weight**: `w_interdigitation = 2.0`

---

## Common-Centroid SVG: ABBA Pattern

```svg
<svg viewBox="0 0 820 520" xmlns="http://www.w3.org/2000/svg" font-family="'Inter', 'Segoe UI', sans-serif">
  <title>Common-Centroid ABBA Placement Pattern</title>
  <rect width="820" height="520" fill="#060C18"/>

  <!-- Title -->
  <text x="30" y="28" fill="#00C4E8" font-size="14" font-weight="bold">Common-Centroid ABBA Pattern — 2-Finger Differential Pair</text>

  <!-- Grid background -->
  <defs>
    <pattern id="smallgrid" width="40" height="40" patternUnits="userSpaceOnUse">
      <path d="M 40 0 L 0 0 0 40" fill="none" stroke="#0D1E35" stroke-width="0.5"/>
    </pattern>
  </defs>
  <rect x="40" y="50" width="730" height="180" fill="url(#smallgrid)" rx="2"/>
  <rect x="40" y="50" width="730" height="180" fill="none" stroke="#14263E" stroke-width="1" rx="2"/>

  <!-- Row label -->
  <text x="20" y="148" fill="#3E5E80" font-size="11" transform="rotate(-90,20,148)">Row 0</text>

  <!-- Device A1 (left) -->
  <rect x="80" y="80" width="120" height="90" fill="#09111F" stroke="#1E88E5" stroke-width="2" rx="6"/>
  <text x="140" y="120" fill="#1E88E5" font-size="22" font-weight="bold" text-anchor="middle">A</text>
  <text x="140" y="143" fill="#B8D0E8" font-size="11" text-anchor="middle">M1 (finger 1)</text>
  <text x="140" y="158" fill="#3E5E80" font-size="10" text-anchor="middle">x = 60 µm</text>
  <!-- Pins -->
  <circle cx="80" cy="125" r="4" fill="#00C4E8"/>
  <circle cx="200" cy="125" r="4" fill="#00C4E8"/>
  <text x="66" y="128" fill="#3E5E80" font-size="9">G</text>
  <text x="204" y="128" fill="#3E5E80" font-size="9">D</text>

  <!-- Device B1 -->
  <rect x="220" y="80" width="120" height="90" fill="#09111F" stroke="#EF5350" stroke-width="2" rx="6"/>
  <text x="280" y="120" fill="#EF5350" font-size="22" font-weight="bold" text-anchor="middle">B</text>
  <text x="280" y="143" fill="#B8D0E8" font-size="11" text-anchor="middle">M2 (finger 1)</text>
  <text x="280" y="158" fill="#3E5E80" font-size="10" text-anchor="middle">x = 200 µm</text>
  <circle cx="220" cy="125" r="4" fill="#00C4E8"/>
  <circle cx="340" cy="125" r="4" fill="#00C4E8"/>

  <!-- Device B2 -->
  <rect x="360" y="80" width="120" height="90" fill="#09111F" stroke="#EF5350" stroke-width="2" rx="6"/>
  <text x="420" y="120" fill="#EF5350" font-size="22" font-weight="bold" text-anchor="middle">B</text>
  <text x="420" y="143" fill="#B8D0E8" font-size="11" text-anchor="middle">M2 (finger 2)</text>
  <text x="420" y="158" fill="#3E5E80" font-size="10" text-anchor="middle">x = 340 µm</text>
  <circle cx="360" cy="125" r="4" fill="#00C4E8"/>
  <circle cx="480" cy="125" r="4" fill="#00C4E8"/>

  <!-- Device A2 (right) -->
  <rect x="500" y="80" width="120" height="90" fill="#09111F" stroke="#1E88E5" stroke-width="2" rx="6"/>
  <text x="560" y="120" fill="#1E88E5" font-size="22" font-weight="bold" text-anchor="middle">A</text>
  <text x="560" y="143" fill="#B8D0E8" font-size="11" text-anchor="middle">M1 (finger 2)</text>
  <text x="560" y="158" fill="#3E5E80" font-size="10" text-anchor="middle">x = 480 µm</text>
  <circle cx="500" cy="125" r="4" fill="#00C4E8"/>
  <circle cx="620" cy="125" r="4" fill="#00C4E8"/>

  <!-- Dummy devices -->
  <rect x="660" y="80" width="80" height="90" fill="#09111F" stroke="#3E5E80" stroke-width="1.5" stroke-dasharray="5,3" rx="6"/>
  <text x="700" y="118" fill="#3E5E80" font-size="11" text-anchor="middle">DUM</text>
  <text x="700" y="134" fill="#3E5E80" font-size="10" text-anchor="middle">dummy</text>
  <text x="700" y="148" fill="#3E5E80" font-size="9" text-anchor="middle">(not connected)</text>

  <!-- Symmetry axis -->
  <line x1="420" y1="52" x2="420" y2="250" stroke="#00C4E8" stroke-width="2" stroke-dasharray="8,4"/>
  <text x="424" y="66" fill="#00C4E8" font-size="10">Symmetry Axis</text>
  <text x="424" y="78" fill="#00C4E8" font-size="10">x = 270 µm</text>

  <!-- Centroid markers -->
  <!-- Centroid A = (60 + 480)/2 = 270 -->
  <line x1="270" y1="240" x2="270" y2="250" stroke="#1E88E5" stroke-width="2"/>
  <polygon points="266,240 274,240 270,232" fill="#1E88E5"/>
  <text x="215" y="265" fill="#1E88E5" font-size="11">x̄_A = 270 µm</text>

  <!-- Centroid B = (200 + 340)/2 = 270 -->
  <line x1="270" y1="240" x2="270" y2="250" stroke="#EF5350" stroke-width="2" stroke-dasharray="3,2"/>
  <text x="295" y="265" fill="#EF5350" font-size="11">x̄_B = 270 µm ✓</text>

  <!-- X centroid line A (arrows to both A devices) -->
  <line x1="140" y1="235" x2="415" y2="235" stroke="#1E88E5" stroke-width="1" stroke-dasharray="3,2"/>
  <line x1="560" y1="235" x2="425" y2="235" stroke="#1E88E5" stroke-width="1" stroke-dasharray="3,2"/>
  <circle cx="140" cy="235" r="3" fill="#1E88E5"/>
  <circle cx="560" cy="235" r="3" fill="#1E88E5"/>
  <circle cx="270" cy="235" r="5" fill="#1E88E5"/>

  <!-- X centroid line B -->
  <line x1="280" y1="248" x2="420" y2="248" stroke="#EF5350" stroke-width="1" stroke-dasharray="3,2"/>
  <line x1="420" y1="248" x2="420" y2="248" stroke="#EF5350" stroke-width="1"/>
  <circle cx="280" cy="248" r="3" fill="#EF5350"/>
  <circle cx="420" cy="248" r="3" fill="#EF5350"/>
  <circle cx="270" cy="248" r="5" fill="#EF5350" opacity="0.8"/>

  <!-- Net connections for device A (gate tied together) -->
  <path d="M 80 100 L 60 100 L 60 60 L 780 60 L 780 100 L 620 100" fill="none" stroke="#1E88E5" stroke-width="1.2" stroke-dasharray="4,2"/>
  <text x="680" y="56" fill="#1E88E5" font-size="9">VIN+ (gate of M1)</text>
  <path d="M 200 105 L 200 73 L 500 73 L 500 105" fill="none" stroke="#1E88E5" stroke-width="1" stroke-dasharray="2,3"/>

  <!-- Net connections for device B (gate tied together) -->
  <path d="M 220 100 L 205 100 L 205 57 L 360 57" fill="none" stroke="#EF5350" stroke-width="1.2" stroke-dasharray="4,2"/>
  <text x="362" y="53" fill="#EF5350" font-size="9">VIN- (gate of M2)</text>
  <path d="M 340 105 L 340 72 L 360 72 L 360 105" fill="none" stroke="#EF5350" stroke-width="1" stroke-dasharray="2,3"/>

  <!-- Explanation box -->
  <rect x="40" y="290" width="730" height="210" fill="#09111F" stroke="#14263E" stroke-width="1" rx="6"/>
  <text x="405" y="314" fill="#00C4E8" font-size="13" font-weight="bold" text-anchor="middle">ABBA Pattern Analysis</text>

  <text x="60" y="338" fill="#B8D0E8" font-size="12" font-weight="bold">Group A (M1, 2 fingers at x = 60, 480 µm)</text>
  <text x="60" y="356" fill="#3E5E80" font-size="11">  Centroid x̄_A = (60 + 480) / 2 = 270 µm</text>
  <text x="60" y="372" fill="#3E5E80" font-size="11">  Any linear doping/temp gradient G(x): ΔP_A ∝ G(60) + G(480)</text>

  <text x="60" y="396" fill="#B8D0E8" font-size="12" font-weight="bold">Group B (M2, 2 fingers at x = 200, 340 µm)</text>
  <text x="60" y="414" fill="#3E5E80" font-size="11">  Centroid x̄_B = (200 + 340) / 2 = 270 µm</text>
  <text x="60" y="430" fill="#3E5E80" font-size="11">  Any linear doping/temp gradient G(x): ΔP_B ∝ G(200) + G(340)</text>

  <text x="60" y="454" fill="#B8D0E8" font-size="12" font-weight="bold">Mismatch:</text>
  <text x="60" y="472" fill="#43A047" font-size="11">  ΔP = ΔP_A - ΔP_B ∝ g₁₀·(x̄_A - x̄_B) = g₁₀ × 0 = 0</text>
  <text x="60" y="488" fill="#43A047" font-size="11">  Linear gradient mismatch is cancelled regardless of g₁₀ magnitude.</text>
</svg>
```

---

## LDE-Related Cost Terms

### LDE Cost (`computeLde`)

Piggybacks on `matching` constraints. For each matched pair, computes approximate SA (source-to-STI-edge) and SB (drain-to-STI-edge) distances by scanning all device positions:

```
SA_i = min(x_i - w_i/2, min over left neighbors of (left_edge_i - right_edge_neighbor))
SB_i = min(layout_width - (x_i + w_i/2), min over right neighbors)
cost += (SA_a - SA_b)² + (SB_a - SB_b)²
```

Default weight: `w_lde = 0.5`

### Thermal Mismatch (`computeThermalMismatch`)

Piggybacks on `matching` constraints. Uses inverse-square heat field model:

```
T(x,y) = Σ_k P_k / max(|pos - H_k|², ε)   where ε = 1.0 µm²
cost += (T(pos_a) - T(pos_b))²
```

Heat sources provided via `SaExtendedInput.heat_sources`. Default weight: `w_thermal = 0.5`

### Edge Penalty (`computeEdgePenalty`)

Counts exposed edges (left/right/top/bottom) for each matched device. An exposed edge is one with no adjacent device (dummy or real) within a threshold. Penalizes asymmetry in edge exposure count:

```
ea = countExposedEdges(dev_a, ...)  // 0-4
eb = countExposedEdges(dev_b, ...)  // 0-4
cost += (ea - eb)²
```

Default weight: `w_edge_penalty = 0.5`

### WPE Mismatch (`computeWpeMismatch`)

Piggybacks on `matching` constraints. For each matched pair, computes minimum distance to the nearest well edge from `WellRegion` inputs:

```
dist_a = min distance from dev_a centre to any well edge
dist_b = min distance from dev_b centre to any well edge
cost += (dist_a - dist_b)²
```

`WellRegion` inputs provided via `SaExtendedInput.well_regions`. Default weight: `w_wpe = 0.5`

### Parasitic Routing Balance (`computeParasiticBalance`)

Piggybacks on `matching` constraints. For each net shared by matched devices, estimates routing lengths as Manhattan distance from device position to net centroid:

```
L_route = |x_device - x_net_centroid| + |y_device - y_net_centroid|
cost += (L_route_a - L_route_b)²
```

Default weight: `w_parasitic = 0.8`

---

## Constraint Cost Weight Summary

| Constraint / Term | Weight Field | Default | Evaluated In |
|---|---|---|---|
| HPWL (half-perimeter wire length) | `w_hpwl` | 1.0 | `computeHpwlAll` |
| Bounding-box area | `w_area` | 0.5 | `computeArea` |
| X-axis symmetry | `w_symmetry` | 2.0 | `computeSymmetry` |
| Matching (parabolic well) | `w_matching` | 1.5 | `computeMatching` |
| Proximity (max distance) | `w_proximity` | 1.0 | `computeProximity` |
| Isolation (min distance) | `w_isolation` | 1.0 | `computeIsolation` |
| RUDY congestion overflow | `w_rudy` | 0.3 | `rudy_grid.totalOverflow` |
| Device overlap | `w_overlap` | 100.0 | `computeOverlap` |
| Thermal mismatch | `w_thermal` | 0.5 | `computeThermalMismatch` |
| Orientation mismatch | `w_orientation` | 2.0 | `computeOrientationMismatch` |
| LDE (SA/SB equalization) | `w_lde` | 0.5 | `computeLde` |
| Common-centroid | `w_common_centroid` | 2.0 | `computeCommonCentroid` |
| Parasitic routing balance | `w_parasitic` | 0.8 | `computeParasiticBalance` |
| Interdigitation | `w_interdigitation` | 2.0 | `computeInterdigitation` |
| Edge penalty | `w_edge_penalty` | 0.5 | `computeEdgePenalty` |
| WPE mismatch | `w_wpe` | 0.5 | `computeWpeMismatch` |

The very high weight on overlap (`w_overlap = 100.0`) effectively makes overlap a near-hard constraint: any configuration with overlapping devices has a cost so much higher than constraint violations that the SA will preferentially eliminate overlaps first.

---

## Guard Ring: Post-SA Validation

Guard rings are not enforced as a cost term during SA. Instead, `checkGuardRings()` is called after SA convergence:

```zig
pub fn checkGuardRings(
    positions: []const [2]f32,
    dimensions: []const [2]f32,
    constraints: []const Constraint,
    wells: []const WellRegion,
    allocator: std.mem.Allocator,
) []const GuardRingResult
```

This returns `GuardRingResult` entries for devices that are not properly enclosed by a well region. The result is included in `SaResult.guard_ring_results` for the caller to inspect and potentially remediate.

A complete guard ring requires:
1. The device bounding box is fully enclosed within a `WellRegion`.
2. The WellRegion is connected (no gaps — a fence, not one fencepost).
3. A well tap is present within the WellRegion at appropriate spacing.

Requirements 2 and 3 are geometry checks performed at the GDS level after export; the SA-level check only verifies condition 1 (bounding box enclosure).
