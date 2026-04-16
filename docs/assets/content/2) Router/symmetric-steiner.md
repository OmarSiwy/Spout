# Symmetric Steiner Tree Builder

**Source:** `src/router/symmetric_steiner.zig`
**Phase:** Phase 4 — Symmetric topology generation for differential / matched nets

---

## Mathematical Background

### Minimum Spanning Tree vs Steiner Tree

A **Minimum Spanning Tree (MST)** connects a set of terminal nodes using the shortest total wire length without adding any extra nodes. For `n` terminal pins the MST always produces exactly `n - 1` edges and the topology is fully determined by the pin positions.

A **Steiner tree** extends the MST concept by allowing the insertion of additional *Steiner points* — intermediate vertices that are not pins but reduce total wire length by creating branching junctions. For Manhattan (rectilinear) geometry, Steiner points always lie at axis-aligned intersections of the bounding box of the terminal set. The **Rectilinear Steiner Minimum Tree (RSMT)** problem is NP-complete in general; Spout delegates the exact Steiner construction to `steiner.zig::SteinerTree.build`.

The Steiner tree is strictly equal to or shorter than the MST:

```
L_Steiner ≤ L_MST
```

For a 4-pin H-pattern with pins at the corners of a square of side `s`, the MST costs `3s` while the Steiner tree costs `2s + s/2 = 2.5s` via a central Steiner point.

### Why Symmetry Matters for Analog

Matched analog structures — differential pairs, current mirrors, resistor ladders — rely on **identical electrical properties** for both arms of the circuit. The dominant sources of mismatch after device sizing are:

| Source | Mechanism |
|---|---|
| Wire length difference | Resistance mismatch → DC offset |
| Via count difference | Via resistance mismatch |
| Routing proximity to aggressor | Different capacitive coupling |
| Thermal gradient | Self-heating skews threshold voltage |

The symmetric Steiner tree eliminates wire-length mismatch **by construction**: the mirrored tree has identical topology and therefore identical total Manhattan length for every net. Via counts can differ if the A\* router takes different layer transitions; those are corrected post-hoc by `MatchedRouter.balanceViaCounts`.

---

## Algorithm

### Overview

```
Input:  pins_ref[]   — world-coordinate pin positions for net A
        pins_mirror[] — world-coordinate pin positions for net B
        net_ref, net_mirror — NetIdx handles

Step 1. Compute centroid of each pin set.
Step 2. Measure centroid separation: dx = |cx_ref - cx_mirror|,
                                      dy = |cy_ref - cy_mirror|.
Step 3. If dx >= dy  →  axis = .y  (vertical mirror axis, axis_value = average X)
        Else          →  axis = .x  (horizontal mirror axis, axis_value = average Y)
Step 4. Build SteinerTree on pins_ref.
Step 5. Mirror each segment of the reference tree around the chosen axis.
Step 6. Tag reference segments with net_ref, mirror segments with net_mirror.

Output: SymmetricSteinerResult{segments_ref, segments_mirror, axis, axis_value}
```

### Axis Selection

The axis passes through the midpoint between the two centroids:

```
dx = |c_ref[x] - c_mir[x]|
dy = |c_ref[y] - c_mir[y]|

if dx >= dy:
    axis       = .y                              // vertical axis (mirrors X)
    axis_value = (c_ref[x] + c_mir[x]) * 0.5

else:
    axis       = .x                              // horizontal axis (mirrors Y)
    axis_value = (c_ref[y] + c_mir[y]) * 0.5
```

The `>=` favors the `.y` axis (vertical) in the tie case.

### Segment Mirroring

For each segment `(x1, y1) → (x2, y2)` in the reference tree:

| Axis | Transformation |
|---|---|
| `.y` (vertical) | `x_new = 2 * axis_value - x_old` ; Y unchanged |
| `.x` (horizontal) | `y_new = 2 * axis_value - y_old` ; X unchanged |

This is a reflection formula: the distance from each point to the axis is preserved, the sign is flipped.

### Degenerate Cases

| Condition | Behavior |
|---|---|
| Both `pins_ref` and `pins_mirror` empty | Return two empty slice results, axis = `.y`, axis_value = 0.0 |
| `pins_ref` empty | Build Steiner on `pins_mirror`; axis = `.y` through mirror centroid; mirror that tree for ref side |
| `pins_mirror` empty | Build Steiner on `pins_ref`; axis = `.y` through ref centroid; mirror for mirror side |
| Either pin set has exactly 1 pin | `SteinerTree.build` produces 0 segments → both slices empty |

---

## SVG Diagram

```svg
<svg xmlns="http://www.w3.org/2000/svg" width="780" height="420" viewBox="0 0 780 420">
  <style>
    text { font-family: 'Inter', 'Segoe UI', sans-serif; font-size: 13px; fill: #B0BEC5; }
    .label-small { font-size: 11px; fill: #78909C; }
    .label-accent { fill: #00C4E8; font-size: 12px; }
    .label-green  { fill: #43A047; font-size: 12px; }
    .label-red    { fill: #EF5350; font-size: 12px; }
    .label-title  { font-size: 15px; font-weight: 600; fill: #E0E0E0; }
  </style>

  <!-- Background -->
  <rect width="780" height="420" fill="#060C18" rx="10"/>

  <!-- Title -->
  <text x="390" y="32" text-anchor="middle" class="label-title">Symmetric Steiner Tree — Differential Pair (axis = .y)</text>

  <!-- Mirror axis (dashed vertical line) -->
  <line x1="390" y1="55" x2="390" y2="375" stroke="#FFC107" stroke-width="1.5" stroke-dasharray="8 5"/>
  <text x="394" y="72" fill="#FFC107" font-size="12" font-family="'Inter','Segoe UI',sans-serif">axis = .y</text>
  <text x="394" y="88" fill="#FFC107" font-size="11" font-family="'Inter','Segoe UI',sans-serif">x = 390</text>

  <!-- ── Reference tree (left, net A, blue) ── -->

  <!-- Pins A -->
  <circle cx="160" cy="120" r="7" fill="#1E88E5"/>
  <circle cx="160" cy="300" r="7" fill="#1E88E5"/>
  <circle cx="280" cy="200" r="7" fill="#1E88E5"/>
  <circle cx="230" cy="340" r="7" fill="#1E88E5"/>

  <!-- Pin labels -->
  <text x="135" y="116" class="label-accent">A1</text>
  <text x="135" y="297" class="label-accent">A2</text>
  <text x="285" y="197" class="label-accent">A3</text>
  <text x="235" y="357" class="label-accent">A4</text>

  <!-- Steiner point -->
  <circle cx="230" cy="200" r="5" fill="none" stroke="#1E88E5" stroke-width="1.5"/>
  <circle cx="230" cy="300" r="5" fill="none" stroke="#1E88E5" stroke-width="1.5"/>

  <!-- Reference tree segments -->
  <!-- A1 → Steiner (230,200) -->
  <line x1="160" y1="120" x2="160" y2="200" stroke="#1E88E5" stroke-width="2"/>
  <line x1="160" y1="200" x2="230" y2="200" stroke="#1E88E5" stroke-width="2"/>
  <!-- A2 → Steiner (230,300) -->
  <line x1="160" y1="300" x2="230" y2="300" stroke="#1E88E5" stroke-width="2"/>
  <!-- A3 is at (280,200), connect to Steiner -->
  <line x1="230" y1="200" x2="280" y2="200" stroke="#1E88E5" stroke-width="2"/>
  <!-- Vertical spine (230,200)→(230,300) -->
  <line x1="230" y1="200" x2="230" y2="300" stroke="#1E88E5" stroke-width="2"/>
  <!-- A4 at (230,340) to steiner 230,300 -->
  <line x1="230" y1="300" x2="230" y2="340" stroke="#1E88E5" stroke-width="2"/>

  <!-- Length annotation net A -->
  <rect x="60" y="385" width="260" height="22" rx="4" fill="#0D1A2E"/>
  <text x="190" y="401" text-anchor="middle" class="label-accent">Net A — L = 320 μm</text>

  <!-- ── Mirror tree (right, net B, green) ── -->

  <!-- Mirrored pins B: x_new = 2*390 - x_old = 780 - x_old -->
  <!-- B1 = (780-160, 120) = (620,120) -->
  <!-- B2 = (780-160, 300) = (620,300) -->
  <!-- B3 = (780-280, 200) = (500,200) -->
  <!-- B4 = (780-230, 340) = (550,340) -->
  <circle cx="620" cy="120" r="7" fill="#43A047"/>
  <circle cx="620" cy="300" r="7" fill="#43A047"/>
  <circle cx="500" cy="200" r="7" fill="#43A047"/>
  <circle cx="550" cy="340" r="7" fill="#43A047"/>

  <text x="628" y="116" class="label-green">B1</text>
  <text x="628" y="297" class="label-green">B2</text>
  <text x="462" y="197" class="label-green">B3</text>
  <text x="558" y="357" class="label-green">B4</text>

  <!-- Mirrored Steiner points -->
  <circle cx="550" cy="200" r="5" fill="none" stroke="#43A047" stroke-width="1.5"/>
  <circle cx="550" cy="300" r="5" fill="none" stroke="#43A047" stroke-width="1.5"/>

  <!-- Mirror tree segments (x reflected) -->
  <line x1="620" y1="120" x2="620" y2="200" stroke="#43A047" stroke-width="2"/>
  <line x1="620" y1="200" x2="550" y2="200" stroke="#43A047" stroke-width="2"/>
  <line x1="620" y1="300" x2="550" y2="300" stroke="#43A047" stroke-width="2"/>
  <line x1="550" y1="200" x2="500" y2="200" stroke="#43A047" stroke-width="2"/>
  <line x1="550" y1="200" x2="550" y2="300" stroke="#43A047" stroke-width="2"/>
  <line x1="550" y1="300" x2="550" y2="340" stroke="#43A047" stroke-width="2"/>

  <!-- Length annotation net B -->
  <rect x="460" y="385" width="260" height="22" rx="4" fill="#0D1A2E"/>
  <text x="590" y="401" text-anchor="middle" class="label-green">Net B — L = 320 μm ✓ equal</text>

  <!-- Centroid markers -->
  <circle cx="217" cy="240" r="4" fill="#FFC107"/>
  <text x="180" y="256" fill="#FFC107" font-size="10" font-family="'Inter','Segoe UI',sans-serif">centroid A</text>
  <circle cx="563" cy="240" r="4" fill="#FFC107"/>
  <text x="530" y="256" fill="#FFC107" font-size="10" font-family="'Inter','Segoe UI',sans-serif">centroid B</text>

  <!-- Legend -->
  <rect x="22" y="55" width="120" height="80" rx="5" fill="#0D1A2E" stroke="#1E3A5C" stroke-width="1"/>
  <line x1="32" y1="75" x2="62" y2="75" stroke="#1E88E5" stroke-width="2"/>
  <text x="68" y="79">Net A (ref)</text>
  <line x1="32" y1="95" x2="62" y2="95" stroke="#43A047" stroke-width="2"/>
  <text x="68" y="99">Net B (mirror)</text>
  <line x1="32" y1="115" x2="62" y2="115" stroke="#FFC107" stroke-width="1.5" stroke-dasharray="6 4"/>
  <text x="68" y="119">Mirror axis</text>
</svg>
```

---

## Data Structures

### `Segment`

```zig
pub const Segment = struct {
    x1: f32,
    y1: f32,
    x2: f32,
    y2: f32,
    net: NetIdx,

    pub fn length(self: Segment) f32  // Manhattan: |x2-x1| + |y2-y1|
};
```

Single rectilinear segment with net ownership. Length is Manhattan (L1) distance. For a segment with `x2 = 3, y2 = 4` from origin, length = 7.

### `SymmetricSteinerResult`

```zig
pub const SymmetricSteinerResult = struct {
    segments_ref:    []Segment,           // reference tree segments, tagged net_ref
    segments_mirror: []Segment,           // mirror tree segments, tagged net_mirror
    axis:            SymmetryAxis,        // .x or .y
    axis_value:      f32,                 // world-coordinate of the axis
    allocator:       std.mem.Allocator,   // owns both segment slices

    pub fn deinit(self: *SymmetricSteinerResult) void
};
```

Both `segments_ref` and `segments_mirror` are heap-allocated slices owned by the result. `deinit` frees both slices. After `deinit` the struct is set to `undefined` to catch use-after-free.

**Guarantee:** `segments_ref.len == segments_mirror.len` and `totalLength(segments_ref) == totalLength(segments_mirror)` (floating-point exact, since mirror is a coordinate transformation only).

---

## Function Reference

### `buildSymmetric`

```zig
pub fn buildSymmetric(
    allocator:    std.mem.Allocator,
    pins_ref:     []const [2]f32,
    pins_mirror:  []const [2]f32,
    net_ref:      NetIdx,
    net_mirror:   NetIdx,
) !SymmetricSteinerResult
```

Main entry point. Builds the pair of Steiner trees. Allocates all segment slices on `allocator`. Returns `error.OutOfMemory` on allocation failure. Degenerate cases do not allocate (return empty slices from the stack-constant `&.{}`).

**Called by:** `MatchedRouter.routeGroup` for differential and matched group types.

---

### `buildSingleTree`

```zig
pub fn buildSingleTree(
    allocator: std.mem.Allocator,
    pins:      []const [2]f32,
    net:       NetIdx,
) ![]Segment
```

Builds a Steiner tree for a single net with no symmetry requirement. Used by `MatchedRouter` for matched groups with 3 or more nets where only one net needs a topology (no mirror partner). Returns empty slice for 0 or 1 pins. The caller owns the returned slice.

---

### `centroid` (private)

```zig
fn centroid(points: []const [2]f32) [2]f32
```

Arithmetic mean of x and y coordinates. Returns `{0, 0}` for empty input. Called twice in the normal path (once per pin set) to determine axis selection.

---

### `mirrorSteinerSegments` (private)

```zig
fn mirrorSteinerSegments(
    allocator: std.mem.Allocator,
    segments:  []const SteinerTree.Segment,
    axis:      SymmetryAxis,
    axis_val:  f32,
) ![]Segment
```

Allocates a new `[]Segment` slice of the same length, fills it by calling `mirrorSteinerSegment` for each element. The returned slice has `net = NetIdx.fromInt(0)` (placeholder); callers replace the net field afterward. Intermediate allocation freed by callers after copying.

---

### `mirrorSteinerSegment` (private)

```zig
fn mirrorSteinerSegment(seg: SteinerTree.Segment, axis: SymmetryAxis, val: f32) Segment
```

Pure function, no allocation. Applies the reflection formula:

| Axis | x1 | y1 | x2 | y2 |
|---|---|---|---|---|
| `.y` | `2*val - seg.x1` | `seg.y1` | `2*val - seg.x2` | `seg.y2` |
| `.x` | `seg.x1` | `2*val - seg.y1` | `seg.x2` | `2*val - seg.y2` |

---

### `totalLength`

```zig
pub fn totalLength(segs: []const Segment) f32
```

Sum of `length()` over all segments. Used by `MatchedRouter.balanceWireLengths` to measure imbalance between the two net trees.

---

### `netTotalLength`

```zig
pub fn netTotalLength(segs: []const Segment, net: NetIdx) f32
```

Filters by `net` identity (`.toInt()` comparison) and sums lengths. Used when a mixed segment list combines multiple nets and only one needs to be measured.

---

## Edge Cases

| Case | What happens |
|---|---|
| Both pin sets empty | Both result slices are empty constant `&.{}`. No allocation. `axis = .y`, `axis_value = 0.0` |
| `pins_ref` empty, `pins_mirror` non-empty | Builds Steiner on mirror side. Both result slices are heap-allocated copies of that tree (ref side gets a copy; mirror side gets the mirror of that tree). Axis is `.y` through mirror centroid X |
| `pins_mirror` empty, `pins_ref` non-empty | Symmetric to above. Note: result slices are swapped — the ref side gets the direct copy, mirror side gets the reflection |
| Either side has 1 pin | `SteinerTree.build` with 1 pin produces 0 segments. Both slices empty |
| Pins not geometrically symmetric | Algorithm does not require geometric symmetry. Axis is determined purely from centroid separation. Topology is mirrored; electrical symmetry is enforced even if physical placement is asymmetric |
| Centroid separation equal in X and Y (`dx == dy`) | `dx >= dy` is true (equality), so `.y` axis selected (vertical) |
| Infeasible topology (pins on same point) | `SteinerTree.build` handles degenerate cases; this module passes through whatever topology it produces |

---

## Memory Model

All allocation uses the caller-provided `allocator`. Two heap slices are produced: `segments_ref` and `segments_mirror`. Both are freed by `SymmetricSteinerResult.deinit`.

Intermediate allocations (`mirror_raw` slices) are freed within `buildSymmetric` before returning; they do not escape.

`buildSingleTree` returns a caller-owned `[]Segment`; the caller must free it directly with `allocator.free`.

---

## Integration with `MatchedRouter`

`MatchedRouter.routeGroup` calls `buildSymmetric` to obtain the Steiner topology, then routes each edge using A\*:

```
for each edge in segments_ref:
    route ref-net edge with A*
for each edge in segments_mirror:
    route mirror-net edge with A*
```

After A\* routing, length balance is checked:

```
delta = |totalLength(segments_p) - totalLength(segments_n)|
if delta > tolerance:
    balanceWireLengths(shorter_net)   → adds perpendicular jog
```

Via count balance is checked separately via `balanceViaCounts`.

---

## Test Coverage

| Test | What is verified |
|---|---|
| `symmetric Steiner tree mirrors correctly — 2 pins` | `.y` axis, `axis_value = 5.5`, equal segment counts, equal total lengths |
| `symmetric Steiner tree horizontal axis` | `.x` axis, `axis_value = 5.0` for Y-separated pins |
| `symmetric Steiner tree both empty` | Both slices empty, no crash |
| `symmetric Steiner tree single pin each side` | Both slices empty (1-pin Steiner = 0 segments) |
| `symmetric Steiner tree length equality — 4-pin group` | 4-pin groups, `1e-3` length tolerance |
| `buildSingleTree basic` | 3-pin tree, `segs.len > 0`, all segments tagged with correct net |
| `buildSingleTree single pin` | Returns empty slice |
| `buildSingleTree empty pins` | Returns empty slice |
| `segment length` | `(0,0)→(3,4)` = 7.0 Manhattan |
| `netTotalLength filters by net` | Mixed-net slice, filters correctly by `NetIdx` |
