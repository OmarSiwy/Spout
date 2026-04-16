FOR INLINE DRC CHECKER:

# DRC Rule Taxonomy for Constraint-Embedded Maze Routing

This document catalogs every design rule relevant to a maze router that embeds
constraints at expansion time, with geometric definitions, required data structures,
per-step computational cost, and known corner cases.

---

## 0. Preliminaries — Metric and Representation

**Projection gap (Manhattan default):**

```
gap_x = max(ax0 − bx1,  bx0 − ax1)   // horizontal gap
gap_y = max(ay0 − by1,  by0 − ay1)   // vertical gap
proj_gap = max(gap_x, gap_y)
proj_gap < 0     → overlap (short)
proj_gap = 0     → touching
proj_gap > 0     → separation distance
```

This is the default metric in Magic, KLayout, and OpenROAD's FlexGC. Some rules
(optionally) use Euclidean distance. SKY130 uses projection (Manhattan) for all
rules in `src/characterize/drc.zig`.

**Router state maintained during search:**

- WireRect list: all committed segments (AABB per segment, net, layer)
- Grid occupancy grid per layer (from `src/router/grid.zig`)
- Per-net rip-up list (for incremental reroute)

---

## 1. Spacing Rules

### 1.1 Basic Metal-to-Metal Spacing (Same Layer)

**Geometric condition:**
Two shapes A, B on the same layer violate `min_spacing` if
`proj_gap(A, B) < min_spacing` and `net(A) ≠ net(B)`.

If `proj_gap < 0` (overlap), this is a **short** — different-net shapes that
overlap are illegal. Same-net overlap is permitted (they are electrically joined;
Magic's tile plane merges overlapping same-net paint).

**SKY130 values (from `pdks/sky130.json`):**

```
M1: min_spacing = 0.14 µm   (layer index 0)
M2: 0.14 µm   (index 1)
M3: 0.14 µm   (index 2)
M4: 0.28 µm   (index 3)
M5: 0.28 µm   (index 4)
LI: 0.17 µm   (special, li_min_spacing)
```

**Data structures needed:**

- Spatial query structure (segment AABB list, queried per expansion step)
- Net identity per segment (to skip same-net checks)
- Layer index per query (to skip cross-layer pairs)

**Computational cost:**

- **O(k)** per expansion step, where k = number of segments on same layer
  within `proj_gap + min_spacing` window.
- With bounding-box prefiltering (sort by x_min, break when `x_min > cutoff`):
  effectively O(log n + m) where m = candidates in window.
- Spout's `InlineDrcChecker.checkSpacing` (in `src/router/inline_drc.zig`)
  does a linear scan of all segments on the layer — O(n) worst-case, acceptable
  for small to medium n (tens of thousands of segments).

**Lookahead/backtracking:**

- None required for basic spacing. The router can fail a step immediately
  upon detecting `proj_gap < min_spacing`.

**Special cases:**

- `touching` (proj_gap = 0): not a violation for same-layer same-net; different-net
  touching may or may not be illegal depending on rule (SKY130: touching allowed,
  overlap forbidden).
- Overlap of different-net shapes on same layer: blocked as short (hard violation).

---

### 1.2 Same-Net vs Different-Net Spacing

**Geometric condition:**
Same as 1.1, but the rule has two thresholds:

- `min_spacing`: enforced between shapes of **different nets**
- `same_net_spacing`: enforced between shapes of **the same net** (notch/slot rule)

For SKY130, `same_net_spacing == min_spacing` for all metal layers (from
`pdks/sky130.json`):

```
same_net_spacing: [0.14, 0.14, 0.14, 0.28, 0.28, 1.6, 0.0, 0.0]
```

So same-net and different-net spacing are identical. Other PDKs may differ.

**Data structures needed:**

- Net identity on every committed segment
- Branch in checkSpacing: `if (seg.net == query.net) use same_net_spacing else min_spacing`

**Computational cost:**

- Same as 1.1 (net comparison is O(1)).
- In `InlineDrcChecker.checkSpacing`, same-net segments are skipped via
  `if (seg.net.toInt() == net.toInt()) continue;` — one integer comparison.

**Corner case — connectivity merges:**
Shapes on the same net that touch (proj_gap = 0) are electrically equivalent.
If two segments from the same net are placed such that they touch, they become one
connected shape. A subsequent segment that approaches the merged shape from a
different-net perspective must still respect spacing. The `InlineDrcChecker`
handles this by always querying against all segments regardless of connectivity —
the result is conservative but correct.

---

### 1.3 Spacing to Vias

Vias are rectangles on a cut layer (e.g., via.44 for M1-M2 in SKY130). They have
their own spacing rules to surrounding metal and to other vias.

**Geometric condition — Via-to-Metal:**
A via shape V on layer (cut) must be enclosed by surrounding metal on each
connected layer by at least `min_enclosure` on all four sides. Additionally,
metal shapes on the same layer as V must not be closer than `min_spacing` to V.

SKY130 via enclosure rules (`pdks/sky130.json`, enc_rules):

```
M1 enclosing via (68/20 over 67/44):  0.06 µm
M2 enclosing via (69/20 over 68/44):  0.03 µm
LI enclosing via (67/20 over 66/44):  0.0 µm  (no enclosure rule)
M2 over M1 via:                       0.03 µm
```

Via-to-metal spacing uses the metal's `min_spacing` against the via rectangle.

**Geometric condition — Via-to-Via:**
Two via shapes on the same cut layer violate if
`proj_gap(vi, vj) < min_spacing_via`. Different nets do not relax this.

**Via enclosure check (from `src/characterize/drc.zig`):**
For each inner shape (e.g., licon on layer 66/44), find all overlapping outer
shapes (e.g., diff on layer 65/44) and compute per-side enclosure:

```
side_best[0] = max(ix0 − ox0)  // left enclosure
side_best[1] = max(ox1 − ix1)  // right enclosure
side_best[2] = max(iy0 − oy0)  // bottom enclosure
side_best[3] = max(oy1 − iy1)  // top enclosure
```

If any side < enclosure requirement → violation.

**Data structures needed:**

- Via shapes tracked separately (cut layer rectangles) — they are routing
  obstacles on the metal layers but have their own enclosure rules.
- Enc_rules array in PdkConfig: `[{outer_layer, inner_layer, enclosure}]`

**Computational cost:**

- Via-to-metal: O(n) per via checked against all metal shapes on both
  connected layers.
- Via-to-via: O(m²) for m vias on same cut layer, but cut layers are sparse
  (fewer via shapes than metal shapes).
- Enclosure check in Spout's DRC (line 538-580 in `src/characterize/drc.zig`):
  for each inner shape, scans all shapes on the target outer layer —
  O(n_outer) per inner shape. With n=10000 shapes, worst-case O(n²) if
  every shape has an enc_rule. Use spatial index to bound this.

**Corner case — via arrays:**
A cut array (multiple cuts in one via cell) must be treated as a single
rectangle for enclosure purposes — the enclosure is measured to the outer
boundary of the array, not individual cuts. SKY130's current router does not
generate via arrays; single-cut vias are used.

---

### 1.4 Wide Metal Spacing (Width-Dependent Spacing)

**Geometric condition:**
When metal width W > threshold, minimum spacing increases:

```
if W >= wide_threshold:
    spacing = wide_spacing  (typically larger)
else:
    spacing = min_spacing
```

SKY130 does NOT have width-dependent spacing for metal layers (the `widespacing`
rule in Magic is not used for SKY130 metals in Spout's current PDK config).
The wide metal rule appears in Magic's drc.scm but is not mapped into
`pdks/sky130.json`. However, this capability is noted as a gap.

**Data structures needed:**

- Track width of each committed segment (route width can differ from min_width)
- Wide threshold table per layer

**Computational cost:**

- O(1) to compute; width is already known during expansion.
- Only affects candidate generation when W exceeds threshold.

**Special case:**
If the router is placing a wide power bus, spacing must be rechecked using
the wide metal rule. A candidate point that is legal for a narrow wire may be
illegal for a wide one.

---

### 1.5 Notch and Isolated Spacing

**Notch:** A re-entrant corner (concave vertex) in a single polygon where two
edges of the same net meet. The minimum notch is the same-net spacing measured
at the re-entrant corner.

**Isolated spacing:** Spacing between two separate polygons of the same net
(which are not electrically connected — there is no path between them on the
same layer).

SKY130 sets `same_net_spacing == min_spacing` for all metal layers, so notch
and isolated spacing equal the standard spacing. No special computation needed.

For PDKs that distinguish these: Magic's `spacing` rule with `touching_ok` vs
`touching_illegal` controls whether same-net touching is treated as a notch
or allowed. KLayout has separate `notch` and `isolated` functions.

**Data structures:**

- Same as same-net spacing (1.2). The geometric test is identical:
  `proj_gap(same_net) < same_net_spacing → violation`.

**Computational cost:**

- Same as basic spacing (1.1).

---

### 1.6 EOL (End-of-Line) Spacing

**Geometric condition:**
An end-of-line (a line-end stub or the terminus of a longer wire) has a
shorter minimum spacing to an adjacent parallel wire than the standard
minimum spacing. EOL spacing applies when:

1. The target shape has a "short edge" (length below EOL threshold)
2. The target shape is oriented parallel to the EOL edge
3. The EOL edge and target shape are within the EOL spacing distance

**How EOL is defined in practice (from FlexGC_eol.cpp in OpenROAD):**

```
An edge is EOL if it is a boundary edge of length <= EOL_length
between a metal shape and empty space (or different type)
```

For SKY130, EOL rules exist for poly and metal layers but are not currently
implemented in Spout's inline DRC checker.

**From `ARCHITECTURE_OPENROAD.md` (LEF encoding):**

```
SPACING <value> [LL <value>]  // LL = end-of-line lookahead length
```

The `LL` keyword specifies the EOL parallel run length beyond which the
EOL rule applies.

**Data structures needed for EOL detection:**

- For each candidate point, need to know: is the committed shape at this
  location an EOL (line-end)? This requires looking at the full segment
  geometry — not just the point.
- EOL detection: if a segment's length in the direction perpendicular to
  the candidate approach is below `EOL_threshold`, it is an EOL.
- EOL rules require accessing the full segment list to determine segment
  endpoints — a point query is insufficient.
- **Lookahead required**: A candidate cannot know if it is at an EOL without
  examining the full geometry of the segment it would join or abut.
- **Backtracking**: If a segment is placed and later found to be an EOL,
  all positions within EOL spacing of its end must be blocked. This requires
  retroactively updating the obstacle map.

**Computational cost:**

- Detecting EOL: O(1) per segment (compare segment length vs threshold)
- Enforcing EOL spacing: for each EOL endpoint, mark a circular (or square)
  exclusion zone of radius `eol_spacing` around it. This is O(n) updates per
  segment committed.
- A\* expansion step: additional check against EOL exclusion zones — O(k) where
  k = number of EOL endpoints in range.

**Corner case — jog handling:**
When a wire makes a 90° turn, both arms of the jog have EOL behavior at the
corner. The corner point itself has two incident edges (the two arms) and is
not an EOL, but the points just before the turn on each arm are.

---

### 1.7 PRL (Parallel Run Length) Spacing

**Geometric condition:**
Two parallel wire segments have increased minimum spacing if their overlapping
length along the parallel axis exceeds a threshold:

```
if parallel_overlap_length >= prl_threshold:
    spacing = prl_spacing  (typically larger than min_spacing)
else:
    spacing = min_spacing
```

KLayout encoding (from `RESEARCH.md`):

```ruby
layer.space(projection, projecting >= 2.um, 1.6).output("PRL >= 2um spacing")
```

The `projecting >= 2.um` clause means: consider two shapes as having PRL
interaction if one projects onto the other by at least 2 µm.

**Data structures needed:**

- For each pair of candidate parallel wires, compute the overlap of their
  bounding projections along the parallel axis.
- Requires access to segment geometry (not just AABB center points).
- **Lookahead required**: PRL spacing depends on the final geometry of the
  wire pair — a segment placed now may later find itself in a PRL relationship
  with a segment placed after it.

**Computational cost:**

- Per expansion step, checking PRL requires comparing the candidate segment's
  projection against all other segments on the same layer with parallel orientation.
- Projection overlap computation: O(1) per pair (compute interval overlap).
- But finding all candidates: O(n) scan, or O(log n) with spatial index.
- PRL is inherently a **bilateral** constraint — neither wire knows the final
  state when being placed. Both segments must enforce the rule against each other.

**Corner case — stub PRL:**
A short stub branching off a longer wire creates a partial-parallel region.
The PRL rule typically applies only to the portion of the wires that is truly
parallel. The stub region may be treated as EOL rather than PRL.

---

## 2. Width Rules

### 2.1 Minimum Width Enforcement

**Geometric condition:**
A wire of width W violates `min_width` if `W < min_width`.
Width is measured as the minimum of the wire's spatial extent along both axes
(for a Manhattan wire oriented along one axis, the smaller of the cross-section
thickness and the length — but in DRC, width is always the cross-section
dimension perpendicular to current flow).

**SKY130 values:**

```
M1: min_width = 0.14 µm   (index 0)
M2: 0.14 µm   (index 1)
M3: 0.14 µm   (index 2)
M4: 0.30 µm   (index 3)
M5: 0.30 µm   (index 4)
LI: 0.17 µm   (special, li_min_width)
```

**Enforcement during routing:**
The router assigns a width to each segment. The width is a parameter to
`addSegment` in `InlineDrcChecker`. During A\* expansion, a candidate point
represents a wire of some width w; if w < min_width, the move is illegal.

**Data structures:**

- Width parameter per segment
- `min_width[layer]` table from PdkConfig

**Computational cost:**

- O(1) per expansion step: compare w against `min_width[layer]`.

**Corner case — jog width:**
When a wire makes a 90° turn, the jog region has a cross-section that is
wider than min_width in one dimension. The width constraint only applies to
the wire's cross-section perpendicular to its length; the jog area is not
a separate wire.

---

### 2.2 Maximum Width

**Geometric condition:**
A wire of width W violates `max_width` if `W > max_width`.
Rarely used for standard metals; more common for diffusion/poly where
active area rules restrict shape size.

Magic's `maxwidth` rule and KLayout's `with_bbox_width` both handle this.
SKY130 does not specify max_width for metal layers in the current PDK config.

**Data structures:**

- `max_width[layer]` table (currently all zeros in SKY130)

**Computational cost:**

- O(1) per expansion step.

---

## 3. Via Rules

### 3.1 Via Enclosure

**Geometric condition:**
A via cut rectangle (inner) must be surrounded by metal (outer) on all four
sides by at least `enclosure` distance:

```
For each side s ∈ {left, right, bottom, top}:
    enc_s = outer_s_max − inner_s_min   (for left/bottom)
            OR inner_s_max − outer_s_min (for right/top)
    if enc_s < enclosure_required → violation
```

SKY130 via enclosure rules (`enc_rules` in `pdks/sky130.json`):

```json
{"outer_layer": 68, "outer_datatype": 20, "inner_layer": 67, "inner_datatype": 44, "enclosure": 0.06}
{"outer_layer": 65, "outer_datatype": 44, "inner_layer": 66, "inner_datatype": 44, "enclosure": 0.12}
{"outer_layer": 69, "outer_datatype": 20, "inner_layer": 68, "inner_datatype": 44, "enclosure": 0.03}
...
```

**Data structures:**

- Enc_rules table: for each (outer_layer, outer_dt, inner_layer, inner_dt) → enclosure value
- Via shape to be committed: must be checked against all metal shapes on
  both connected layers

**Computational cost:**

- For each via committed, scan all metal shapes on the outer layer.
- O(n) per via in the naive implementation.
- Use spatial index (grid or R-tree) to find metal shapes that overlap the
  via's bounding box + enclosure halo.

**Corner case — stacked vias:**
A via from L1 to L2 placed directly above a via from L2 to L3 (stacked) has
special enclosure rules. The lower via's top enclosure (to L3 metal) must be
checked, and the upper via's bottom enclosure (to L1 metal) must also be checked.
SKY130 handles stacked vias through the sequence of enc_rules applied per via.

**Corner case — multiple outer shapes:**
The enclosure check in `src/characterize/drc.zig` (line 538-580) takes the **maximum**
enclosure from any outer shape on each side independently. This handles cases
where two outer shapes together enclose an inner shape — each side uses the
best outer shape available. This is critical for L-shaped or partial enclosures.

---

### 3.2 Via-to-Via Spacing

**Geometric condition:**
Two via cuts on the same cut layer violate if `proj_gap(via1, via2) < min_spacing`.
Via-to-via spacing is checked on the cut layer, not on the metal layers.

**SKY130:**
Cut layer spacing for via.44 (licon) is 0.17 µm; for via.44/via2/m2 contact,
the cut-to-cut spacing is 0.15 µm (from `via_width` array, used as cut size).

**Data structures:**

- Cut layer segments tracked separately
- Cut layer `min_spacing` value

**Computational cost:**

- O(n) per via committed, checking against all prior vias on same cut layer.
- Spatial index (grid) makes this O(k) where k = vias in same grid cell neighborhood.

**Corner case — via arrays:**
Arrayed vias have cut spacing rules between array elements and must present
a single outer boundary for enclosure checks. The router currently does not
generate via arrays.

---

### 3.3 Via-to-Metal Spacing

**Geometric condition:**
A via cut on cut layer C must maintain `min_spacing` from metal shapes on all
layers (not just the two connected metal layers). This is typically handled
by running spacing checks on the metal layers against the via rectangle as
if the via were a metal shape.

In Spout's DRC (`src/characterize/drc.zig`), vias are treated as shapes on
their cut layer datatype, and cross-layer spacing checks handle via-to-metal
via the `cross_rules` table.

**SKY130 cross_rules that involve vias:**

```json
{
  "layer_a": 66,
  "datatype_a": 20,
  "layer_b": 65,
  "datatype_b": 20,
  "min_spacing": 0.075
}
```

(poly to diff — not via-related, but shows cross-layer spacing structure)

**Data structures:**

- Cross_rules table for cross-layer spacing
- Via shapes tracked as WireRects on cut layers

**Computational cost:**

- Per via, check against metal shapes on all connected layers.
- O(n) without spatial index, O(k) with grid.

---

### 3.4 Minimum Via Size

**Geometric condition:**
A via cut rectangle must have both dimensions >= `min_via_width` (SKY130 uses
the `via_width` array for this):

```
M1-M2 via (via.44): min via size = 0.17 µm
M2-M3 via: 0.17 µm
M3-M4 via: 0.15 µm
M4-M5 via: 0.20 µm
```

**Data structures:**

- `via_width[layer]` array in PdkConfig

**Computational cost:**

- O(1) per via committed.

---

## 4. Antenna Rules

### 4.1 Gate Area to Metal Area Ratio

**Geometric condition:**
The ratio of (total metal area on layer L) to (gate area) must not exceed
a threshold. This prevents charge accumulation on the gate oxide during
manufacturing (plasma etching can charge gates, causing oxide damage if the
metal antenna is too large relative to the gate).

**Formally:**

```
antenna_ratio = sum(area(metal_shape_i)) / gate_area
if antenna_ratio > threshold → violation at the via connecting metal to gate
```

The violation is attributed to the **via** connecting the metal to the gate,
not to the metal shape itself.

**Why antenna rules are hard to embed incrementally in a maze router:**

1. **Cumulative property**: The antenna ratio depends on ALL metal connected
   to the gate through a chain of vias. A via placed now may later accumulate
   more metal area from subsequent routing, becoming a violation retroactively.
2. **Non-monotonic**: Adding metal can only increase the ratio (never decrease),
   but removing metal requires rip-up and reroute.
3. **Lookahead required**: To know if placing a segment is safe, the router must
   know the total metal area that will eventually connect to the same gate through
   the same via path. This requires a forward model of how much metal will be
   added in the future.
4. **Per-net connectivity graph needed**: The router must maintain a connectivity
   graph (net → shapes) to compute which metals share a gate connection.

**Incremental approximation strategies:**

- **Upper bound heuristic**: Track the total metal area per net. Place an upper
  bound on how much area can be added before the ratio exceeds the threshold.
  If area + projected_additional > threshold × gate_area, block the addition.
  Conservative (may over-block) but safe.
- **Diode insertion point**: If a net exceeds the ratio, a diode can be inserted
  to bleed charge. This is a post-routing repair step (handled by separate antenna
  repair in OpenROAD's `RepairAntennas.cpp`).

**Data structures needed:**

- Gate area per net (from device extraction — gate shapes on poly/diff)
- Total metal area accumulated per net (maintained during routing)
- Antenna ratio threshold per gate type (from PDK)

**Computational cost:**

- Per segment committed: O(1) to update net area accumulator.
- Per candidate evaluation: O(1) to check against remaining budget.
- Periodic full recomputation: O(n) to recalculate all nets from scratch.

---

## 5. Density Rules

### 5.1 Sliding Window Density

**Geometric condition:**
For every position (x, y), compute the metal density in a sliding window of
size W × W centered at (x, y). The density is:

```
density = area(metal in window) / window_area
if density < min_density OR density > max_density → violation at (x, y)
```

Metal density rules ensure uniform CMP (chemical-mechanical polishing) planarity.
Violations are regions, not just points.

**Why density rules are hard to embed in a maze router:**

1. **Global property**: A segment placed anywhere affects density in all windows
   that cover it. A local decision (placing a wire at point P) has non-local
   consequences (increases density in many windows across the chip).
2. **Window sliding is O(n³) naive**: For n windows × m shapes, naive computation
   is O(n×m). With a quadtree or rasterized grid, this can be approximated.
3. **Incremental update is complex**: Adding a segment updates density in all
   windows it overlaps — potentially thousands of windows.
4. **Post-routing fill**: Most commercial flows handle density via **metal fill**
   (dummy metal added after routing to meet density targets). The router typically
   does not need to embed density constraints; fill is a separate step.

**Router embedding strategy:**

- Track per-grid-cell density (grid resolution = window_step)
- When a segment is committed, increment density in all cells it overlaps
- Before committing a candidate: check if it would push any overlapped cell
  above max_density or below min_density
- Grid-based density is O(1) per cell update, O(k) candidate check where
  k = number of cells the candidate rectangle overlaps.

**SKY130 density:**
Not currently embedded in Spout's router. The router targets routing geometry
correctness; metal fill is a separate step.

---

## 6. Corner Cases

### 6.1 Layer Transitions (Stacked Vias)

When routing from layer L1 to L2, a via is placed. Immediately above or below
that via, another via may be stacked. Layer transition rules include:

- Enclosure of lower via by L3 metal (for stacked L2-L3 via above L1-L2 via)
- Minimum spacing from the stacked via to adjacent wires on intermediate layers
- Interaction of via enclosures across layers

**Handling in Spout:**
Each via committed is checked against enc_rules for both connected layers.
Stacked via interactions are handled by the fact that both vias are in the
segment list and spacing is checked between all pairs.

**Computational cost:**

- O(2) enclosure checks per via (one for each connected metal layer)
- O(n) via-to-via spacing check against all prior vias

---

### 6.2 Jog Handling (90-Degree Turns)

A 90° jog creates two segments: one horizontal, one vertical, meeting at a
corner point. Key constraints at the jog:

1. **Width at jog**: The jog region (the union of the two segments near the
   corner) must not create a shape narrower than min_width. For a standard
   90° turn with both arms at min_width, the jog region is always >= min_width.
   However, if one arm is wider than min_width, the jog must be handled carefully.

2. **Spacing near jog**: The corner point is not an EOL, but the points just
   before the corner on each arm behave like EOLs (see 1.6). The jog's inner
   corner is a concave vertex that may trigger notch rules for same-net shapes.

3. **Via placement at jog**: In the current Spout maze router, vias are only
   placed at pin terminals, not at jogs. The router uses a direct-drop topology
   (single-layer trunk + vertical drops to pins, no jogs in the trunk). This
   eliminates the jog-handling complexity.

**In a general maze router with jogs:**

- For each jog point, the jog region must be checked for min_width (notch)
- EOL spacing applies to the arm endpoints before the jog
- PRL spacing: the two arms are not parallel to each other, so PRL does not
  apply between them; PRL applies only within each arm separately

---

### 6.3 Terminal and Stub Handling

A terminal (wire end) is an EOL. The EOL spacing rule (1.6) applies to all
wire ends. Stubs (short branches from a main wire) also have EOL behavior
at their far end, but the junction with the main wire is not an EOL.

**In the channel router (Spout's maze.zig):**

- Trunk lines are long horizontal wires with no stubs
- Pin connections are short vertical drops from the trunk to the pin
- The pin stub end (near the pin) is an EOL; the trunk is long and not an EOL

**Stub length consideration:**
A stub shorter than the EOL length threshold is fully EOL-constrained.
A stub longer than the EOL threshold becomes a proper wire with PRL rules
on its long edges.

---

### 6.4 Hierarchical Cell Boundaries

When routing through hierarchical cells, shapes in sub-cells interact with
shapes in parent cells and sibling cells. The boundary of a cell instance
creates special cases:

1. **Overlap at cell boundaries**: Shapes from different instances that abut
   at cell edges may appear to overlap or violate spacing when the cell is
   flattened, but are legal due to abutment rules.

2. **Halo clearance**: Cells with pins have a halo region where routing is
   blocked to prevent shorts to the cell's internal geometry.

3. **Master cell vs instance**: In Spout's flat representation, all geometry
   is flattened at export time. The router does not currently handle cell
   hierarchy internally — all shapes are in a single flat namespace.

**For hierarchical routers:**

- Must track cell instance boundaries
- Shape interactions across cell boundaries must respect the cell's internal
  rules (e.g., a pin shape in a cell may have specific clearance requirements)
- Border cell instances add a halo zone around the cell's bounding box

---

### 6.5 Off-Grid to On-Grid Conversion During Routing

The router operates on a grid (from `src/router/grid.zig`), with tracks at
specific pitches. Routing is constrained to track positions (on-grid), but
the PDK rules are in micrometers (continuous). The conversion creates edge cases:

1. **Grid snapping error**: A candidate point at (x, y) is snapped to the
   nearest grid intersection. The snapped point may be off by up to half a
   grid pitch from the ideal position. If this snapped position violates
   spacing while the ideal position would not (or vice versa), the grid
   resolution must be fine enough to avoid systematic undercounting.

2. **Width vs grid alignment**: A wire of width w, when placed on a grid,
   may extend beyond the grid cell's center by half the wire width. The
   WireRect representation in `InlineDrcChecker` uses actual geometry
   (half-width expansion around segment centerline), not grid cells. This
   is geometrically correct.

3. **Via placement on grid**: Vias are placed at grid intersections. The
   via's enclosure is measured in micrometers, not grid units. A via placed
   on a grid point may have its enclosure geometry misaligned with respect
   to surrounding metal if the metal tracks are offset from the via grid.

**Spout's approach:**

- Wire geometry is stored in micrometers, not grid cell indices
- Grid is used for spatial indexing and candidate generation
- Projection gap computed in micrometer space (continuous geometry)
- Grid snapping only applies to the router's search graph vertices, not to
  the committed geometry representation

---

## 7. Summary Table

| Rule                     | Geometry Test                                        | Data Structures                       | Cost per Expansion                   | Lookahead?                  |
| ------------------------ | ---------------------------------------------------- | ------------------------------------- | ------------------------------------ | --------------------------- |
| min_spacing (diff net)   | proj_gap < min_spacing                               | WireRect list, net identity           | O(k) candidates in window            | No                          |
| min_spacing (same net)   | proj_gap < same_net_spacing                          | net identity                          | O(k)                                 | No                          |
| min_width                | min(w, h) < min_width                                | width param                           | O(1)                                 | No                          |
| max_width                | max(w, h) > max_width                                | width param                           | O(1)                                 | No                          |
| via enclosure            | max(enc_s) < enclosure on any side                   | enc_rules, outer shapes               | O(n_outer) per via                   | No                          |
| via-to-via spacing       | proj_gap(v1, v2) < min_spacing_cut                   | cut layer WireRects                   | O(m) cuts on layer                   | No                          |
| via-to-metal spacing     | proj_gap(via, metal) < min_spacing                   | cross_rules                           | O(n)                                 | No                          |
| min_via_size             | min(v_w, v_h) < via_width                            | via_width array                       | O(1)                                 | No                          |
| wide metal spacing       | W > threshold → spacing = wide_spacing               | wide_threshold table                  | O(1)                                 | No                          |
| EOL spacing              | edge.length < EOL_thresh AND proj_gap < eol_spacing  | segment geometry, EOL zones           | O(k) + O(eol_endpoints)              | Yes (retroactive update)    |
| PRL spacing              | overlap_length >= prl_thresh → spacing = prl_spacing | segment geometry                      | O(n) scan for parallel candidates    | Yes (bilateral)             |
| notch (same-net)         | proj_gap(same_net) < same_net_spacing                | same as same-net spacing              | O(k)                                 | No                          |
| antenna ratio            | sum(area) / gate_area > threshold                    | gate_area per net, metal area per net | O(1) update, O(n) periodic recompute | Yes (upper bound heuristic) |
| density (sliding window) | density in window outside [min, max]                 | per-grid density accumulator          | O(k) cells overlapped                | No (incremental update)     |
| stacked via              | enc_rules checked per via layer                      | enc_rules, via list                   | O(2) per via                         | No                          |
| jog width                | jog region min(w,h) >= min_width                     | width params                          | O(1)                                 | No                          |
| jog EOL                  | arm endpoint is EOL                                  | segment geometry                      | O(1) per arm                         | No                          |
| grid snapping            | WireRect uses actual µm, not grid                    | micrometer geometry                   | O(1)                                 | No                          |

---

## 8. Rule Interactions and Dependency Graph

```
Candidate placement
       │
       ├─ width check ──────────────────→ min_width / max_width
       │
       ├─ spacing check (same layer) ─→ min_spacing (diff net)
       │                                    same_net_spacing
       │                                    notch
       │
       ├─ cross-layer spacing ─────────→ cross_rules (poly-diff, metal-diff, etc.)
       │
       ├─ via placement ────────────────→ via enclosure (enc_rules)
       │                                    via-to-via spacing
       │                                    via-to-metal spacing
       │                                    min_via_size
       │
       ├─ EOL check ───────────────────→ EOL spacing (if arm is line-end)
       │                                    jog handling
       │
       ├─ PRL check ───────────────────→ PRL spacing (if parallel overlap > threshold)
       │
       ├─ density update ──────────────→ sliding window density
       │
       └─ antenna update ───────────────→ antenna ratio (cumulative)
```

---

## 9. Open Gaps in Current Implementation

Based on review of `src/router/inline_drc.zig`, `src/router/maze.zig`, and
`pdks/sky130.json`:

1. **EOL spacing not implemented**: `InlineDrcChecker` has no EOL detection.
   Trunk lines in maze.zig are long and do not create EOLs, but pin stubs
   are short and may exhibit EOL behavior that is not checked.

2. **PRL spacing not implemented**: No parallel run length check in the
   current DRC.

3. **Wide metal spacing not implemented**: No width-dependent spacing in
   `InlineDrcChecker`.

4. **Via enclosure not checked in inline DRC**: `InlineDrcChecker.checkSpacing`
   only checks metal-to-metal spacing. It does not call enc_rules for via
   enclosure. This means a via can be placed without enclosure verification
   during routing — only caught in the full post-layout DRC.

5. **Density not tracked**: No sliding window density check in the router.

6. **Antenna not tracked**: No cumulative metal area per net.

7. **Same-net overlap handling**: When two same-net segments overlap
   (proj_gap < 0), the InlineDrcChecker skips them (they are merged logically),
   but the segment list still contains two overlapping entries. This is
   handled correctly by the skip-on-overlap logic in checkSpacing.

8. **Hierarchical boundaries not tracked**: Flat representation only.

---

## 10. References

- `src/characterize/drc.zig` — Spout's full DRC engine (sweep-line, projection gap, enc_rules)
- `src/router/inline_drc.zig` — Inline DRC checker for A\* expansion
- `src/router/maze.zig` — Maze router with channel-based routing
- `pdks/sky130.json` — SKY130 rule values (min_spacing, same_net_spacing, enc_rules, cross_rules)
- `ARCHITECTURE_OPENROAD.md` — OpenROAD FlexGC modules (FlexGC_eol.cpp, FlexGC_cut.cpp, FlexGC_metspc.cpp)
- `RESEARCH.md` — Magic vs KLayout DRC comparison (EOL, PRL, antenna, density)
- `references/magic/lisp/scm/drc.scm` — Magic DRC rule definitions (width, spacing, overhang)
- `references/magic/drc/DRCbasic.c` — Magic's tile-based DRC (projection gap formula)
