# DRC Rules — Spout Inline Checker & sky130 Rule Set

> **Audience:** IC design engineers building analog circuits on Spout.
> **Source files:** `src/router/DRC_RULES.md`, `src/router/inline_drc.zig`, `pdks/sky130.json`, `src/characterize/drc.zig`

---

## 1. Overview

Spout's DRC subsystem has two distinct layers:

| Layer | File | Role |
|---|---|---|
| **Inline DRC** | `src/router/inline_drc.zig` | Checks DRC rules at every A\* expansion step during routing. Blocks illegal candidate points before they are committed. |
| **Full post-layout DRC** | `src/characterize/drc.zig` | Sweep-line engine run after GDSII export. Checks the complete layout against all enc_rules, cross_rules, and projection-gap rules. |

The external signoff DRC tool is KLayout (`python/tools.py: run_klayout_drc`), which runs the PDK-provided `.lydrc` script against the exported GDSII. KLayout is the authoritative DRC sign-off; the inline checker is a routing-time guard.

---

## 2. Geometric Foundation

### 2.1 Projection Gap (Manhattan)

All spacing rules in sky130 use the **projection gap** metric (identical to Magic's `DRCbasic.c` and OpenROAD's FlexGC):

```
gap_x = max(ax0 − bx1,  bx0 − ax1)   // horizontal separation
gap_y = max(ay0 − by1,  by0 − ay1)   // vertical separation
proj_gap = max(gap_x, gap_y)

proj_gap < 0   → shapes overlap (potential short)
proj_gap = 0   → shapes touch edge-to-edge
proj_gap > 0   → shapes are separated by proj_gap µm
```

This is a Manhattan metric: two rectangles on the same layer are in violation if their projection onto either axis is closer than the rule minimum. Diagonal separation does not qualify — the dominant axis determines the gap.

### 2.2 Continuous µm Geometry

Wire geometry is stored in micrometers (`f32`), not grid cell indices. The grid is used only for candidate generation and spatial indexing. Projection gaps are computed in µm space, which means:

- Grid snapping errors cannot cause systematic under-checking.
- A wire of width `w` placed on a grid point occupies `[center − w/2, center + w/2]` on each side.
- `WireRect` (in `inline_drc.zig`) expands the centerline by half the wire width to get the actual geometry.

---

## 3. Rule Categories

### 3.1 Spacing Rules

#### 3.1.1 Basic Metal-to-Metal Spacing (Same Layer)

**Physical meaning:** Two metal shapes on the same layer that are too close to each other can electrically bridge during manufacturing, creating an unintended short. The minimum spacing rule enforces a manufacturing margin against this.

**Geometric test:** `proj_gap(A, B) < min_spacing` AND `net(A) ≠ net(B)` → violation

**sky130 values (`pdks/sky130.json`, `min_spacing` array):**

| Index | Layer | Min Spacing | Notes |
|---|---|---|---|
| 0 | LI (local interconnect) | 0.17 µm | `li_min_spacing` field |
| 1 | M1 (metal 1) | 0.14 µm | `min_spacing[0]` |
| 2 | M2 (metal 2) | 0.14 µm | `min_spacing[1]` |
| 3 | M3 (metal 3) | 0.14 µm | `min_spacing[2]` |
| 4 | M4 (metal 4) | 0.28 µm | `min_spacing[3]` |
| 5 | M5 (metal 5) | 0.28 µm | `min_spacing[4]` |

**Computational cost:** O(k) per A\* expansion step, where k = segments on the same layer within the query bounding box. The `InlineDrcChecker` implementation does a linear scan — O(n) worst-case — which is acceptable for designs with tens of thousands of segments.

**Overlap case:** `proj_gap < 0` means different-net shapes overlap. This is a **short** — the hardest category of DRC violation. Same-net overlaps are electrically merged and not a violation.

#### 3.1.2 Same-Net Spacing (Notch Rule)

**Physical meaning:** Re-entrant corners (notches) in a single net's polygon can be sources of electromigration stress concentrations and lithographic printing difficulties.

**Geometric test:** Same as 3.1.1 but applies to `net(A) == net(B)`. The threshold is `same_net_spacing`.

**sky130 values:** `same_net_spacing == min_spacing` for all metal layers:

```json
"same_net_spacing": [0.14, 0.14, 0.14, 0.28, 0.28, 1.6, 0.0, 0.0]
```

Sky130 does not distinguish notch from general spacing — both use the same minimum. Some other PDKs use a relaxed notch rule.

**Implementation:** In `InlineDrcChecker.checkSpacing`, same-net segments are identified by `if (seg.net.toInt() == net.toInt()) continue` — same-net segments are skipped for different-net spacing, then a separate pass applies `same_net_spacing`. Net identity is an integer comparison: O(1).

#### 3.1.3 Spacing to Vias (Via-to-Metal)

**Physical meaning:** A via cut that is too close to a neighboring metal shape can cause the etched via hole to punch into the wrong metal, shorting layers.

**Geometric test:** Metal shapes on the same layer as the via rectangle must be at least `min_spacing` away (measured on the cut layer).

**sky130 values:** Via-to-metal uses the metal layer's `min_spacing`. Via shapes (cut layers) also have their own spacing rules from `aux_rules`:

| GDS Layer | GDS Datatype | Layer Name | Min Width | Min Spacing |
|---|---|---|---|---|
| 66 | 44 | licon (LI contact) | 0.17 µm | 0.17 µm |
| 67 | 44 | mcon (M1 contact) | 0.17 µm | 0.19 µm |
| 68 | 44 | via1 (M1-M2 via) | 0.15 µm | 0.17 µm |

**Implementation:** Via shapes are tracked as `WireRect` entries on cut layer datatypes. `cross_rules` in the PDK JSON encode cross-layer spacing between vias and adjacent material.

#### 3.1.4 End-of-Line (EOL) Spacing

**Physical meaning:** The end of a wire (a line-end terminus) is more susceptible to lithographic "tip rounding" — the exposed photoresist rounds at the end of a narrow line. EOL rules require extra clearance around wire ends to prevent shorting to adjacent structures.

**Geometric test:**
1. An edge is EOL if it is a boundary edge of length ≤ `EOL_threshold`.
2. The EOL edge is oriented parallel to a nearby shape.
3. The parallel shape is within `eol_spacing` of the EOL edge.
4. The parallel shape extends at least `prl_threshold` along the parallel run.

**sky130 implementation status:** EOL rules exist in sky130 (Magic's `drc.scm` encodes them) but are **not currently implemented** in `InlineDrcChecker`. Pin stub ends (short vertical drops from trunk to pin) are EOL geometries that are not checked at routing time. Post-layout KLayout DRC does catch EOL violations.

**Lookahead requirement:** EOL detection requires knowing the full segment geometry — whether a placed segment constitutes a line-end depends on what other segments connect to it. This is an inherently retroactive check.

#### 3.1.5 Parallel Run Length (PRL) Spacing

**Physical meaning:** Two parallel wires that run alongside each other for a long distance have an increased electric field between them (long capacitive coupling region) and require greater spacing to meet signal integrity requirements and prevent systematic shorts from litho/etch variation.

**Geometric test:**
```
if overlap_length_along_parallel_axis >= prl_threshold:
    required_spacing = prl_spacing   (> min_spacing)
else:
    required_spacing = min_spacing
```

**sky130 PRL (from RESEARCH.md, KLayout encoding):**
```ruby
layer.space(projection, projecting >= 2.um, 1.6).output("PRL >= 2um spacing")
```

**Implementation status:** PRL is **not currently implemented** in `InlineDrcChecker`. This is noted as a known gap in `DRC_RULES.md` section 9.

**Bilateral constraint:** A PRL violation involves both wires. Neither wire can independently know the final state when it is first placed. PRL checking requires examining the existing geometry to compute projection overlap.

#### 3.1.6 Wide Metal Spacing

**Physical meaning:** Wide metal lines have larger process variations in their edge placement (CMP dishing, etch loading). A wider wire requires more clearance from its neighbors.

**Geometric test:**
```
if wire_width >= wide_threshold:
    required_spacing = wide_spacing
else:
    required_spacing = min_spacing
```

**sky130 status:** Wide metal spacing for metal layers exists in Magic's `drc.scm` but is **not mapped** into `pdks/sky130.json`. Not currently checked by `InlineDrcChecker`.

---

### 3.2 Width Rules

#### 3.2.1 Minimum Width

**Physical meaning:** A wire narrower than the minimum printable feature size will not be reliably resolved on the wafer. Narrow wires also have high resistance and are electromigration-prone.

**Geometric test:** `min(wire_width, wire_height) < min_width[layer]` → violation
Width is measured as the cross-section dimension perpendicular to current flow.

**sky130 values (`min_width` array):**

| Index | Layer | Min Width |
|---|---|---|
| 0 | LI | 0.17 µm (`li_min_width`) |
| 1 | M1 | 0.14 µm |
| 2 | M2 | 0.14 µm |
| 3 | M3 | 0.14 µm |
| 4 | M4 | 0.30 µm |
| 5 | M5 | 0.30 µm |

**Enforcement:** The router assigns a `width` parameter to every segment. During A\* expansion, `if (w < min_width[layer]) → illegal move`. This is O(1).

**Jog corner note:** At a 90° turn, the jog region has a 2D cross-section (width in both x and y). The DRC rule applies to the wire's intended routing direction — the jog corner area is not checked as a separate shape.

#### 3.2.2 Maximum Width

**Physical meaning:** Certain layers (especially diffusion and poly) have maximum size constraints to limit stress or meet slotting rules. Metal layers may have slot requirements above a width threshold.

**sky130:** Max width for metal layers is not specified in `pdks/sky130.json` (all zeros). The `max_width` field in `PdkConfig` is reserved but unused.

---

### 3.3 Via Rules

#### 3.3.1 Via Enclosure

**Physical meaning:** A metal layer must "enclose" a via cut on all four sides by at least the `enclosure` distance. This ensures the via reliably contacts the metal regardless of mask misalignment (overlay error) during manufacturing.

**Geometric test:** For each via cut (inner shape) and its surrounding metal (outer shape):
```
side_best[left]   = max(inner.x0 − outer.x0)  over all outer shapes
side_best[right]  = max(outer.x1 − inner.x1)
side_best[bottom] = max(inner.y0 − outer.y0)
side_best[top]    = max(outer.y1 − inner.y1)
if any side_best[s] < enclosure_required → violation
```

The implementation in `src/characterize/drc.zig` (lines 538–580) takes the **maximum** enclosure from all outer shapes on each side independently. This correctly handles L-shaped or partial metal enclosures.

**sky130 enc_rules (from `pdks/sky130.json`):**

| Outer Layer | Outer Datatype | Inner Layer | Inner Datatype | Enclosure | Meaning |
|---|---|---|---|---|---|
| 68 | 20 | 67 | 44 | 0.06 µm | M1 enclosing mcon |
| 65 | 44 | 66 | 44 | 0.12 µm | tap enclosing licon |
| 68 | 20 | 68 | 44 | 0.03 µm | M1 enclosing via1 |
| 69 | 20 | 68 | 44 | 0.03 µm | M2 enclosing via1 |
| 67 | 20 | 67 | 44 | 0.0 µm | LI enclosing mcon (no enclosure required) |
| 69 | 20 | 69 | 44 | 0.055 µm | M2 enclosing via2 |
| 67 | 20 | 66 | 44 | 0.08 µm | LI enclosing licon |
| 64 | 20 | 65 | 44 | 0.18 µm | nwell enclosing tap |
| 65 | 20 | 66 | 44 | 0.04 µm | diff enclosing licon |
| 68 | 20 | 66 | 44 | 0.06 µm | M1 enclosing licon |
| 65 | 20 | 66 | 44 | 0.12 µm | diff enclosing licon (alternate) |

**Important gap:** Via enclosure is **not checked** in `InlineDrcChecker.checkSpacing` during routing. It is only caught in the full post-layout DRC run. A via can be placed without enclosure verification at routing time.

#### 3.3.2 Via-to-Via Spacing

**Physical meaning:** Two adjacent vias that are too close will have their etched holes merge, potentially creating a larger-than-intended cut that causes reliability problems.

**Geometric test:** `proj_gap(via1, via2) < min_spacing_cut` on the same cut layer → violation

**sky130 values:**

| Via Cut Layer | Min Via Size | Cut-to-Cut Spacing |
|---|---|---|
| licon (66/44) | 0.17 µm | 0.17 µm (from aux_rules) |
| mcon (67/44) | 0.17 µm | 0.19 µm |
| via1 (68/44) | 0.15 µm | 0.17 µm |
| via2 (69/44) | 0.15 µm | 0.17 µm |
| via3 (70/44) | 0.20 µm | 0.20 µm |

**Note:** Spout's current router generates only single-cut vias; via arrays are not generated.

#### 3.3.3 Minimum Via Size

**Geometric test:** `min(via_width, via_height) < via_width[layer]` → violation

**sky130 values (`via_width` array):**

```json
"via_width": [0.17, 0.17, 0.15, 0.20, 0.20, 0.80, 0.0, 0.0]
```

Indices: [LI, M1-M2 via, M2-M3 via, M3-M4 via, M4-M5 via, ...]

---

### 3.4 Area Rules

**Physical meaning:** Very small isolated metal shapes (slivers) are unreliable — they can lift off during CMP or be completely consumed by etch. Minimum area rules prevent accidental slivers.

**sky130 values (`min_area` array, in µm²):**

| Index | Layer | Min Area |
|---|---|---|
| LI | li_min_area | 0.0561 µm² |
| 0 | M1 | 0.083 µm² |
| 1 | M2 | 0.0676 µm² |
| 2 | M3 | 0.24 µm² |
| 3 | M4 | 0.24 µm² |
| 4 | M5 | 4.0 µm² |

**Implementation status:** Area rules are present in `pdks/sky130.json` and checked by the full DRC engine. They are not checked in the inline router.

---

### 3.5 Cross-Layer Spacing Rules

**Physical meaning:** Some layers that overlap in the stack must maintain minimum separation on different layers to avoid unintended coupling or isolation failure.

**sky130 cross_rules (`pdks/sky130.json`):**

| Layer A | Datatype A | Layer B | Datatype B | Min Spacing | Meaning |
|---|---|---|---|---|---|
| 66 | 20 | 65 | 20 | 0.075 µm | poly to diff |
| 66 | 20 | 65 | 44 | 0.055 µm | poly to tap |
| 66 | 44 | 65 | 20 | 0.19 µm | licon to diff |
| 66 | 44 | 65 | 44 | 0.055 µm | licon to tap |
| 66 | 44 | 66 | 20 | 0.055 µm | licon to poly |
| 65 | 44 | 64 | 20 | 0.13 µm | tap to nwell |
| 65 | 20 | 64 | 20 | 0.34 µm | diff to nwell |

---

### 3.6 Antenna Rules

**Physical meaning:** During plasma etching, metal connected to a gate oxide can accumulate charge. If the ratio of metal area (acting as an antenna) to gate area exceeds a threshold, the charge density is high enough to tunnel through and permanently damage the gate oxide.

**Formal test:**
```
antenna_ratio = sum(area of metal shapes on layer L connected to gate) / gate_area
if antenna_ratio > threshold → violation attributed to the via connecting metal to gate
```

**Why this is difficult to embed in a maze router:**
1. **Cumulative:** The ratio depends on ALL metal connected to the gate through any via path. Metal placed later can make an earlier-placed via retroactively violate the rule.
2. **Non-monotonic:** Adding metal only increases the ratio.
3. **Requires connectivity graph:** The router must maintain a full net-to-shape connectivity map to accumulate gate area vs. metal area.
4. **Lookahead required:** A candidate placement cannot know the final metal area without a forward model.

**Incremental approximation:**
Track total metal area per net. Set an upper bound: if `current_area + projected_additional > threshold × gate_area`, block the addition. This is conservative but safe.

**Implementation status:** Antenna rules are **not tracked** in `InlineDrcChecker`. Post-routing antenna repair is a separate step (similar to OpenROAD's `RepairAntennas.cpp`).

---

### 3.7 Density Rules

**Physical meaning:** Chemical-mechanical polishing (CMP) requires uniform metal density across the chip surface. Low-density regions cause CMP dishing; high-density regions cause erosion. Both degrade planarity and cause thickness variations that affect resistance and capacitance.

**Sliding window test:**
```
for every window position (x, y):
    density = area(metal in W×W window) / W²
    if density < min_density OR density > max_density → violation
```

**Why this is difficult to embed in a router:**
1. **Global property:** A wire at point P affects density in every window that covers P.
2. **Post-routing fill:** Most flows add dummy metal fill after routing to meet density targets. The router does not need to enforce density; fill handles it.
3. **O(n³) naive:** A rasterized grid approximation reduces this to O(k) per segment.

**Implementation status:** Metal density is **not tracked** in Spout's router. Metal fill is a separate post-processing step.

---

## 4. Auxiliary (Cut/Device) Layer Rules

Additional shape rules from `pdks/sky130.json` `aux_rules`:

| GDS Layer | GDS Datatype | Layer Name | Min Width | Min Spacing |
|---|---|---|---|---|
| 65 | 20 | diff (active diffusion) | 0.26 µm | 0.27 µm |
| 65 | 44 | tap (body tap) | 0.17 µm | 0.27 µm |
| 66 | 20 | poly | 0.15 µm | 0.21 µm |
| 66 | 44 | licon | 0.17 µm | 0.17 µm |
| 67 | 44 | mcon | 0.17 µm | 0.19 µm |
| 68 | 44 | via1 | 0.15 µm | 0.17 µm |
| 64 | 20 | nwell | 0.84 µm | 1.27 µm |

---

## 5. How Rules Are Encoded in the PDK JSON

`pdks/sky130.json` has six rule categories:

```json
{
  "min_spacing":   [M1, M2, M3, M4, M5, LI, -, -],   // index 0=LI routing layer
  "min_width":     [M1, M2, M3, M4, M5, LI, -, -],
  "via_width":     [LI, M1via, M2via, M3via, M4via, ..],
  "min_enclosure": [LI, M1, M2, M3, M4, M5, -, -],
  "metal_pitch":   [M1, M2, M3, M4, M5, LI, -, -],
  "same_net_spacing": [same as min_spacing for sky130],
  "min_area":      [M1, M2, M3, M4, M5, -, -, -],
  "aux_rules":     [{gds_layer, gds_datatype, min_width, min_spacing, min_area}...],
  "enc_rules":     [{outer_layer, outer_datatype, inner_layer, inner_datatype, enclosure}...],
  "cross_rules":   [{layer_a, datatype_a, layer_b, datatype_b, min_spacing}...],
  "layer_map":     [GDS layer numbers for LI, M1, M2, M3, M4, M5],
  "layers":        {name: [gds_layer, gds_datatype] | [[gds_layer, gds_datatype]...]}
}
```

Arrays are 8 elements wide for extensibility; unused slots are 0.0. The routing layer index convention (from `src/core/route_arrays.zig`) is: index 0 = LI, 1 = M1, 2 = M2, ..., 5 = M5.

---

## 6. DRC Engine Architecture

### 6.1 Inline DRC (Routing-Time)

`InlineDrcChecker` in `src/router/inline_drc.zig` embeds DRC into the A\* maze router expansion loop:

```
A* expansion step at candidate point P:
    1. Determine layer, width, net for candidate segment
    2. checkWidth(layer, width)         → O(1)
    3. checkSpacing(layer, candidate_rect, net, segments_on_layer)  → O(k)
    4. if any check fails → reject candidate
    5. if all checks pass → add candidate to open set
```

The `WireRect` (axis-aligned bounding box per segment) is the fundamental geometric representation. Each segment stores: layer, x1, y1, x2, y2 (centerline), width.

Spacing check expands the candidate's half-width on all sides and tests projection gap against all segments on the same layer.

**Computational bound:** For a design with n total segments and k segments on the same layer within the spacing window, each expansion step costs O(k). With k ≈ n in the worst case (single-layer design), the total search cost is O(n × steps). Practical designs have k ≪ n due to layer separation.

### 6.2 Full Post-Layout DRC

`src/characterize/drc.zig` is a sweep-line engine invoked after GDSII export:

1. **Load geometry:** Read all GDS shapes into per-layer lists.
2. **Sweep by layer:** For each layer pair with rules (from `aux_rules`, `enc_rules`, `cross_rules`):
   a. Sort shapes by x_min.
   b. For each shape, scan the active set for shapes within the rule's halo distance.
   c. Compute `proj_gap` for each candidate pair.
   d. If `proj_gap < min_spacing` → record violation with location and rule name.
3. **Enclosure check (enc_rules):** For each inner shape (cut), find all outer shapes (metal) on both connected layers. Compute per-side enclosure margin. If any side < required → violation.
4. **Cross-layer check:** For each `cross_rule`, scan all shapes on layer_a against shapes on layer_b.

**Note from characterize/TODO.md:** The characterize subsystem is "not functional" — Spout uses Magic and KLayout as external dependencies for DRC/LVS/PEX signoff. The DRC engine in `src/characterize/drc.zig` is under development.

---

## 7. Violation Feedback to the Router

When DRC violations are detected post-routing, Spout uses the following repair strategy (from `src/router/pex_feedback.zig`):

1. The `PexFeedbackResult` contains `MatchReport` entries per matched group.
2. Each `MatchReport` has a `failure_reason` field.
3. `repairFromPexReport()` dispatches to the appropriate repair:
   - `r_mismatch` → `repairWidths()` — widens the higher-resistance net's segments
   - `length_mismatch` → `repairLength()` — inserts a perpendicular jog at the midpoint
   - `via_mismatch` → `repairVias()` — adds dummy vias to the net with fewer vias
   - `coupling_mismatch` → `repairCoupling()` — moves the lower-layer net to the next metal up
4. The feedback loop runs up to `MAX_PEX_ITERATIONS = 5` times.

For DRC-specific violations (spacing, enclosure), the repair mechanism is rip-up and reroute: the offending segment is removed from `RouteArrays`, the router is re-invoked with updated obstacle maps, and the inline DRC checker prevents re-routing into the same illegal position.

---

## 8. Summary of Rule Computational Costs

| Rule | Geometric Test | Data Structures | Per-Step Cost | Lookahead? | Implemented? |
|---|---|---|---|---|---|
| min_spacing (diff net) | `proj_gap < min_spacing` | WireRect list + net ID | O(k) | No | Yes |
| min_spacing (same net) | `proj_gap < same_net_spacing` | net ID | O(k) | No | Yes |
| min_width | `w < min_width[layer]` | width param | O(1) | No | Yes |
| max_width | `w > max_width[layer]` | width param | O(1) | No | N/A (no rule) |
| via enclosure | `enc_s < enclosure` per side | enc_rules, outer shapes | O(n_outer) | No | Post-layout only |
| via-to-via spacing | `proj_gap(v1,v2) < cut_spacing` | cut layer WireRects | O(m) | No | Post-layout only |
| min_via_size | `min(vw,vh) < via_width` | via_width array | O(1) | No | Post-layout only |
| EOL spacing | edge.len < EOL_thresh AND gap < EOL_spacing | segment geometry | O(k) + zones | Yes | Not implemented |
| PRL spacing | overlap >= prl_thresh → larger spacing | segment geometry | O(n) scan | Yes | Not implemented |
| notch (same-net) | `proj_gap(same-net) < same_net_spacing` | same as spacing | O(k) | No | Yes |
| antenna ratio | `sum(area)/gate_area > threshold` | gate area per net | O(1) update | Yes (cumulative) | Not implemented |
| density | density in window outside [min, max] | per-grid density | O(k cells) | No | Not implemented |
| via enclosure (inline) | per-side enc < required | enc_rules | O(n_outer) | No | Gap — not checked |
| cross-layer spacing | `proj_gap(layer_a, layer_b) < rule` | cross_rules | O(n) | No | Post-layout only |
| min_area | `polygon_area < min_area[layer]` | area accumulator | O(1) | No | Post-layout only |

---

## 9. DRC Rules Visual Reference

```svg
<svg viewBox="0 0 960 740" xmlns="http://www.w3.org/2000/svg" font-family="'Inter','Segoe UI',sans-serif">
  <!-- Background -->
  <rect width="960" height="740" fill="#060C18"/>

  <!-- Title -->
  <text x="480" y="38" fill="#B8D0E8" font-size="20" font-weight="bold" text-anchor="middle">sky130 DRC Rules — Visual Reference</text>
  <text x="480" y="58" fill="#3E5E80" font-size="12" text-anchor="middle">All dimensions in µm. Layer colors: poly=#EF5350 · M1=#1E88E5 · M2=#AB47BC · diff=#43A047 · via=#FB8C00</text>

  <!-- ═══════════════════ ROW 1 ═══════════════════ -->

  <!-- 1. WIDTH RULE -->
  <g transform="translate(40,80)">
    <rect width="200" height="160" rx="6" fill="#09111F" stroke="#14263E"/>
    <text x="100" y="22" fill="#B8D0E8" font-size="13" font-weight="bold" text-anchor="middle">1. Min Width</text>
    <!-- Wire shape -->
    <rect x="40" y="50" width="120" height="48" rx="3" fill="#1E88E5" fill-opacity="0.8" stroke="#1E88E5"/>
    <!-- Width arrow -->
    <line x1="40" y1="38" x2="160" y2="38" stroke="#00C4E8" stroke-width="1.5" marker-end="url(#arr)" marker-start="url(#arrl)"/>
    <text x="100" y="35" fill="#00C4E8" font-size="10" text-anchor="middle">w ≥ 0.14 µm (M1)</text>
    <!-- Height arrow -->
    <line x1="172" y1="50" x2="172" y2="98" stroke="#00C4E8" stroke-width="1.5" marker-end="url(#arr)" marker-start="url(#arrl)"/>
    <text x="186" y="78" fill="#00C4E8" font-size="9" text-anchor="start">h</text>
    <text x="100" y="130" fill="#3E5E80" font-size="10" text-anchor="middle">M1: 0.14µm  M4: 0.30µm</text>
    <text x="100" y="144" fill="#3E5E80" font-size="10" text-anchor="middle">LI: 0.17µm  M5: 0.30µm</text>
  </g>

  <!-- 2. SPACING RULE -->
  <g transform="translate(260,80)">
    <rect width="200" height="160" rx="6" fill="#09111F" stroke="#14263E"/>
    <text x="100" y="22" fill="#B8D0E8" font-size="13" font-weight="bold" text-anchor="middle">2. Min Spacing</text>
    <!-- Wire A -->
    <rect x="20" y="50" width="60" height="48" rx="3" fill="#1E88E5" fill-opacity="0.8" stroke="#1E88E5"/>
    <text x="50" y="80" fill="#fff" font-size="9" text-anchor="middle">Net A</text>
    <!-- Wire B -->
    <rect x="120" y="50" width="60" height="48" rx="3" fill="#AB47BC" fill-opacity="0.8" stroke="#AB47BC"/>
    <text x="150" y="80" fill="#fff" font-size="9" text-anchor="middle">Net B</text>
    <!-- Spacing arrow -->
    <line x1="82" y1="74" x2="118" y2="74" stroke="#00C4E8" stroke-width="1.5" marker-end="url(#arr)" marker-start="url(#arrl)"/>
    <text x="100" y="68" fill="#00C4E8" font-size="9" text-anchor="middle">s ≥ min</text>
    <text x="100" y="130" fill="#3E5E80" font-size="10" text-anchor="middle">M1/M2/M3: 0.14µm</text>
    <text x="100" y="144" fill="#3E5E80" font-size="10" text-anchor="middle">M4/M5: 0.28µm  LI: 0.17µm</text>
  </g>

  <!-- 3. ENCLOSURE RULE -->
  <g transform="translate(480,80)">
    <rect width="200" height="160" rx="6" fill="#09111F" stroke="#14263E"/>
    <text x="100" y="22" fill="#B8D0E8" font-size="13" font-weight="bold" text-anchor="middle">3. Via Enclosure</text>
    <!-- Metal (outer) -->
    <rect x="25" y="40" width="150" height="80" rx="3" fill="#1E88E5" fill-opacity="0.3" stroke="#1E88E5" stroke-width="1.5"/>
    <text x="170" y="38" fill="#1E88E5" font-size="9">M1</text>
    <!-- Via (inner) -->
    <rect x="70" y="62" width="60" height="36" rx="2" fill="#FB8C00" fill-opacity="0.8" stroke="#FB8C00"/>
    <text x="100" y="84" fill="#fff" font-size="9" text-anchor="middle">via</text>
    <!-- Enclosure arrows (left/right) -->
    <line x1="27" y1="80" x2="69" y2="80" stroke="#00C4E8" stroke-width="1.5" marker-end="url(#arr)" marker-start="url(#arrl)"/>
    <text x="48" y="73" fill="#00C4E8" font-size="8" text-anchor="middle">enc</text>
    <line x1="131" y1="80" x2="173" y2="80" stroke="#00C4E8" stroke-width="1.5" marker-end="url(#arr)" marker-start="url(#arrl)"/>
    <text x="152" y="73" fill="#00C4E8" font-size="8" text-anchor="middle">enc</text>
    <!-- Enclosure arrows (top/bottom) -->
    <line x1="100" y1="42" x2="100" y2="61" stroke="#00C4E8" stroke-width="1.5" marker-end="url(#arr)" marker-start="url(#arrl)"/>
    <line x1="100" y1="99" x2="100" y2="118" stroke="#00C4E8" stroke-width="1.5" marker-end="url(#arr)" marker-start="url(#arrl)"/>
    <text x="100" y="132" fill="#3E5E80" font-size="10" text-anchor="middle">M1 enc via1: 0.06µm</text>
    <text x="100" y="146" fill="#3E5E80" font-size="10" text-anchor="middle">M2 enc via1: 0.03µm</text>
  </g>

  <!-- 4. AREA RULE -->
  <g transform="translate(700,80)">
    <rect width="220" height="160" rx="6" fill="#09111F" stroke="#14263E"/>
    <text x="110" y="22" fill="#B8D0E8" font-size="13" font-weight="bold" text-anchor="middle">4. Min Area</text>
    <!-- Small shape -->
    <rect x="40" y="45" width="55" height="72" rx="3" fill="#1E88E5" fill-opacity="0.7" stroke="#1E88E5"/>
    <text x="67" y="86" fill="#fff" font-size="8" text-anchor="middle">A = w×h</text>
    <!-- Area label -->
    <text x="67" y="130" fill="#00C4E8" font-size="10" text-anchor="middle">A ≥ min_area</text>
    <!-- Table -->
    <text x="145" y="50" fill="#3E5E80" font-size="9">M1: 0.083µm²</text>
    <text x="145" y="64" fill="#3E5E80" font-size="9">M2: 0.0676µm²</text>
    <text x="145" y="78" fill="#3E5E80" font-size="9">M3: 0.24µm²</text>
    <text x="145" y="92" fill="#3E5E80" font-size="9">M4: 0.24µm²</text>
    <text x="145" y="106" fill="#3E5E80" font-size="9">M5: 4.0µm²</text>
    <text x="145" y="120" fill="#3E5E80" font-size="9">LI: 0.0561µm²</text>
  </g>

  <!-- ═══════════════════ ROW 2 ═══════════════════ -->

  <!-- 5. EOL RULE -->
  <g transform="translate(40,270)">
    <rect width="200" height="160" rx="6" fill="#09111F" stroke="#14263E"/>
    <text x="100" y="22" fill="#B8D0E8" font-size="13" font-weight="bold" text-anchor="middle">5. EOL Spacing</text>
    <!-- Long wire (left) -->
    <rect x="20" y="55" width="80" height="40" rx="3" fill="#1E88E5" fill-opacity="0.8" stroke="#1E88E5"/>
    <text x="60" y="78" fill="#fff" font-size="8" text-anchor="middle">wire end →</text>
    <!-- Adjacent wire (right, parallel) -->
    <rect x="130" y="42" width="50" height="66" rx="3" fill="#AB47BC" fill-opacity="0.8" stroke="#AB47BC"/>
    <text x="155" y="78" fill="#fff" font-size="8" text-anchor="middle">adj</text>
    <!-- EOL spacing arrow -->
    <line x1="102" y1="75" x2="128" y2="75" stroke="#00C4E8" stroke-width="1.5" marker-end="url(#arr)" marker-start="url(#arrl)"/>
    <text x="115" y="68" fill="#00C4E8" font-size="8" text-anchor="middle">EOL</text>
    <!-- Not implemented label -->
    <rect x="20" y="118" width="160" height="22" rx="4" fill="#1a0a0a" stroke="#EF5350" stroke-width="1"/>
    <text x="100" y="133" fill="#EF5350" font-size="9" text-anchor="middle">Not implemented in inline DRC</text>
  </g>

  <!-- 6. PRL SPACING -->
  <g transform="translate(260,270)">
    <rect width="200" height="160" rx="6" fill="#09111F" stroke="#14263E"/>
    <text x="100" y="22" fill="#B8D0E8" font-size="13" font-weight="bold" text-anchor="middle">6. PRL Spacing</text>
    <!-- Wire A (horizontal) -->
    <rect x="15" y="50" width="170" height="28" rx="3" fill="#1E88E5" fill-opacity="0.8" stroke="#1E88E5"/>
    <!-- Wire B (horizontal, parallel) -->
    <rect x="15" y="95" width="170" height="28" rx="3" fill="#AB47BC" fill-opacity="0.8" stroke="#AB47BC"/>
    <!-- Spacing arrow -->
    <line x1="100" y1="80" x2="100" y2="93" stroke="#00C4E8" stroke-width="1.5" marker-end="url(#arr)" marker-start="url(#arrl)"/>
    <text x="114" y="88" fill="#00C4E8" font-size="8">s_prl</text>
    <!-- PRL overlap bracket -->
    <line x1="15" y1="135" x2="185" y2="135" stroke="#00C4E8" stroke-width="1" stroke-dasharray="4,3"/>
    <text x="100" y="148" fill="#00C4E8" font-size="8" text-anchor="middle">overlap ≥ 2µm → s_prl = 1.6µm</text>
    <!-- Not implemented -->
    <rect x="20" y="118" width="160" height="16" rx="3" fill="#1a0a0a" stroke="#EF5350" stroke-width="1"/>
    <text x="100" y="129" fill="#EF5350" font-size="9" text-anchor="middle">Not implemented</text>
  </g>

  <!-- 7. NOTCH (SAME-NET) -->
  <g transform="translate(480,270)">
    <rect width="200" height="160" rx="6" fill="#09111F" stroke="#14263E"/>
    <text x="100" y="22" fill="#B8D0E8" font-size="13" font-weight="bold" text-anchor="middle">7. Notch / Same-Net</text>
    <!-- U-shape (same net) -->
    <path d="M 25 50 L 85 50 L 85 85 L 115 85 L 115 50 L 175 50 L 175 100 L 25 100 Z" fill="#1E88E5" fill-opacity="0.7" stroke="#1E88E5" stroke-width="1.5"/>
    <!-- Notch arrow -->
    <line x1="85" y1="60" x2="115" y2="60" stroke="#00C4E8" stroke-width="1.5" marker-end="url(#arr)" marker-start="url(#arrl)"/>
    <text x="100" y="55" fill="#00C4E8" font-size="8" text-anchor="middle">notch</text>
    <line x1="100" y1="87" x2="100" y2="98" stroke="#00C4E8" stroke-width="1.5" marker-end="url(#arr)" marker-start="url(#arrl)"/>
    <text x="100" y="115" fill="#3E5E80" font-size="9" text-anchor="middle">same as min_spacing in sky130</text>
    <text x="100" y="130" fill="#3E5E80" font-size="9" text-anchor="middle">notch ≥ 0.14µm (M1)</text>
  </g>

  <!-- 8. CROSS-LAYER (POLY-DIFF) -->
  <g transform="translate(700,270)">
    <rect width="220" height="160" rx="6" fill="#09111F" stroke="#14263E"/>
    <text x="110" y="22" fill="#B8D0E8" font-size="13" font-weight="bold" text-anchor="middle">8. Cross-Layer Spacing</text>
    <!-- Diff region -->
    <rect x="20" y="50" width="80" height="80" rx="3" fill="#43A047" fill-opacity="0.5" stroke="#43A047"/>
    <text x="60" y="93" fill="#43A047" font-size="9" text-anchor="middle">diff</text>
    <!-- Poly crossing -->
    <rect x="120" y="35" width="28" height="110" rx="3" fill="#EF5350" fill-opacity="0.7" stroke="#EF5350"/>
    <text x="134" y="148" fill="#EF5350" font-size="9" text-anchor="middle">poly</text>
    <!-- Spacing arrow -->
    <line x1="102" y1="90" x2="118" y2="90" stroke="#00C4E8" stroke-width="1.5" marker-end="url(#arr)" marker-start="url(#arrl)"/>
    <text x="110" y="82" fill="#00C4E8" font-size="8" text-anchor="middle">0.075µm</text>
    <text x="110" y="130" fill="#3E5E80" font-size="9" text-anchor="middle">poly-to-diff: 0.075µm</text>
    <text x="110" y="144" fill="#3E5E80" font-size="9" text-anchor="middle">licon-to-diff: 0.19µm</text>
  </g>

  <!-- ═══════════════════ ROW 3: Projection Gap Diagram ═══════════════════ -->
  <g transform="translate(40,460)">
    <rect width="880" height="240" rx="6" fill="#09111F" stroke="#14263E"/>
    <text x="440" y="28" fill="#B8D0E8" font-size="15" font-weight="bold" text-anchor="middle">Projection Gap (Manhattan) — The Core Metric</text>

    <!-- Shape A -->
    <rect x="60" y="60" width="100" height="60" rx="3" fill="#1E88E5" fill-opacity="0.7" stroke="#1E88E5"/>
    <text x="110" y="94" fill="#fff" font-size="11" text-anchor="middle">Shape A</text>
    <text x="110" y="107" fill="#B8D0E8" font-size="9" text-anchor="middle">(ax0,ay0)→(ax1,ay1)</text>

    <!-- Shape B (well-separated) -->
    <rect x="220" y="55" width="90" height="70" rx="3" fill="#AB47BC" fill-opacity="0.7" stroke="#AB47BC"/>
    <text x="265" y="93" fill="#fff" font-size="11" text-anchor="middle">Shape B</text>

    <!-- Proj gap X arrow -->
    <line x1="162" y1="90" x2="218" y2="90" stroke="#00C4E8" stroke-width="2" marker-end="url(#arr)" marker-start="url(#arrl)"/>
    <text x="190" y="82" fill="#00C4E8" font-size="10" text-anchor="middle">gap_x = 56</text>
    <!-- proj_gap label -->
    <text x="190" y="140" fill="#00C4E8" font-size="11" text-anchor="middle">proj_gap = max(gap_x, gap_y) &gt; 0  →  OK</text>

    <!-- Overlapping shapes example -->
    <rect x="440" y="60" width="100" height="60" rx="3" fill="#1E88E5" fill-opacity="0.7" stroke="#1E88E5"/>
    <text x="490" y="94" fill="#fff" font-size="11" text-anchor="middle">Shape C</text>
    <rect x="510" y="55" width="90" height="70" rx="3" fill="#EF5350" fill-opacity="0.6" stroke="#EF5350"/>
    <text x="555" y="93" fill="#fff" font-size="11" text-anchor="middle">Shape D</text>
    <!-- Overlap label -->
    <rect x="506" y="62" width="38" height="56" rx="2" fill="#ffffff" fill-opacity="0.2" stroke="#fff" stroke-dasharray="3,2"/>
    <text x="525" y="148" fill="#EF5350" font-size="11" text-anchor="middle">proj_gap &lt; 0  →  SHORT (hard violation)</text>

    <!-- Just-touching shapes -->
    <rect x="680" y="60" width="80" height="60" rx="3" fill="#1E88E5" fill-opacity="0.7" stroke="#1E88E5"/>
    <rect x="762" y="60" width="80" height="60" rx="3" fill="#AB47BC" fill-opacity="0.7" stroke="#AB47BC"/>
    <text x="800" y="148" fill="#3E5E80" font-size="10" text-anchor="middle">proj_gap = 0  →  touching (allowed same-net)</text>

    <!-- Formula box -->
    <rect x="60" y="162" width="760" height="60" rx="5" fill="#060C18" stroke="#14263E"/>
    <text x="80" y="182" fill="#B8D0E8" font-size="11" font-family="monospace">gap_x = max(ax0 - bx1,  bx0 - ax1)     gap_y = max(ay0 - by1,  by0 - ay1)</text>
    <text x="80" y="200" fill="#B8D0E8" font-size="11" font-family="monospace">proj_gap = max(gap_x, gap_y)</text>
    <text x="80" y="214" fill="#3E5E80" font-size="10">This is the universal spacing test — used for same-layer spacing, cross-layer spacing, via-to-metal, and notch checks.</text>
  </g>

  <!-- Arrowhead markers -->
  <defs>
    <marker id="arr" markerWidth="6" markerHeight="6" refX="5" refY="3" orient="auto">
      <path d="M0,0 L6,3 L0,6 Z" fill="#00C4E8"/>
    </marker>
    <marker id="arrl" markerWidth="6" markerHeight="6" refX="1" refY="3" orient="auto-start-reverse">
      <path d="M0,0 L6,3 L0,6 Z" fill="#00C4E8"/>
    </marker>
  </defs>
</svg>
```

---

## 10. Known Gaps

The following rules are described in `DRC_RULES.md` Section 9 as not yet implemented in the inline checker:

1. **EOL spacing** — pin stubs are short enough to be EOL geometries, but not checked at route time.
2. **PRL spacing** — no parallel run length check.
3. **Wide metal spacing** — no width-dependent spacing table.
4. **Via enclosure (inline)** — only caught post-layout by the full DRC engine.
5. **Metal density** — no sliding-window density accumulator.
6. **Antenna ratio** — no cumulative metal area per net tracking.
7. **Hierarchical cell boundaries** — flat representation only.

Post-layout signoff via KLayout (`python/tools.py: run_klayout_drc`) catches all of these.

---

## 11. References

| File | Purpose |
|---|---|
| `src/router/DRC_RULES.md` | Full algorithmic taxonomy for all rule types |
| `src/router/inline_drc.zig` | Routing-time DRC checker (spacing + width) |
| `src/characterize/drc.zig` | Post-layout DRC engine (sweep-line, enc_rules) |
| `pdks/sky130.json` | sky130 rule values (all arrays and rule tables) |
| `python/tools.py` | External signoff wrappers (KLayout DRC, LVS; Magic PEX) |
| `RESEARCH.md` | Magic vs KLayout DRC engine comparison |
