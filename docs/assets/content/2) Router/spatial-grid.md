# Spatial Grid

## Purpose

`SpatialGrid` is a uniform 2D spatial index that provides O(1) cell lookup and O(1 + k) neighborhood queries for routing-related geometry. It exists to accelerate the DRC spacing checks performed thousands of times per routing pass. Without it, every spacing query would be an O(n) linear scan over all routed segments — prohibitively slow for designs with tens of thousands of wires.

The grid is used in two ways during routing:

1. **DRC coupling checks.** Before placing a new wire segment at position `(layer, x, y)`, the router queries for all existing segments within one cell's neighborhood and checks whether any are too close (spacing violation).

2. **Obstacle queries.** The A* router needs to know whether a candidate grid node is blocked. The spatial grid provides the candidate neighbors that must be tested for overlap.

The grid is designed with explicit constraints: it is **not thread-safe** (read-only during routing, rebuilt between wavefronts) and uses a **uniform grid** (not an R-tree or quadtree) for simplicity and cache-friendliness.

---

## Source File

`src/router/spatial_grid.zig` — 516 lines.

---

## Design: Uniform Grid

The data structure is a classic static spatial hash grid, not a tree. The world space of the die is divided into a uniform grid of rectangular cells, where each cell has the same dimensions `cell_size × cell_size` micrometers.

**Why not an R-tree?**
- R-trees have better worst-case query complexity but require pointer-chasing across nodes — poor cache behavior.
- For IC routing, the distribution of wire segments is relatively uniform (not clustered), making uniform grids competitive.
- The grid can be rebuilt from scratch in O(n) between wavefronts, avoiding the cost of incremental R-tree updates.
- The 3×3 neighborhood query covers 9 cells at most, yielding O(9 × avg_segs_per_cell) work — essentially O(1) for sparse layouts.

**Cell size choice.** The cell size is computed as `max(all_layers.min_spacing) × 2.0`, bounded below by `0.01 µm`. This ensures that any two wire segments that violate spacing rules will always have their bounding boxes overlap at least one shared cell, making them discoverable by a 3×3 neighborhood query. If a segment is wider than one cell it is registered in all cells that its bounding box overlaps.

---

## Imports

```zig
const at = @import("analog_types.zig");
const layout_if = @import("../core/layout_if.zig");

const Rect = at.Rect;
const SegmentIdx = at.SegmentIdx;
const NetIdx = at.NetIdx;
const PdkConfig = layout_if.PdkConfig;
```

The grid works with abstract `SegmentIdx` values — it stores indices into external geometry arrays, not copies of geometry. The caller is responsible for holding the actual coordinates.

---

## `SpatialGrid`

### Fields

| Field | Type | Description |
|-------|------|-------------|
| `cells_x` | `u32` | Number of cells along the X axis. Computed as `ceil(die_width / cell_size) + 1`. The `+1` provides a guard column to prevent off-by-one at the right edge. |
| `cells_y` | `u32` | Number of cells along the Y axis. Same formula for Y. |
| `cell_size` | `f32` | Physical size of one grid cell in micrometers. Equal to `max(min_spacing[i]) × 2.0`, lower-bounded by `0.01`. |
| `origin_x` | `f32` | Die bounding box left edge (`die_bbox.x1`). Subtracted from all world X coordinates before computing cell column. |
| `origin_y` | `f32` | Die bounding box bottom edge (`die_bbox.y1`). Subtracted from all world Y coordinates before computing cell row. |
| `cell_offsets` | `[]u32` | Flat array of length `cells_x × cells_y`. `cell_offsets[cell_idx]` is the starting index into `segment_pool` for that cell's entries. Computed by prefix-sum during `rebuild`. |
| `cell_counts` | `[]u16` | Flat array of length `cells_x × cells_y`. `cell_counts[cell_idx]` is the number of segment indices stored for that cell. Saturating add (`+|= 1`) prevents overflow for pathological inputs. |
| `segment_pool` | `std.ArrayListUnmanaged(SegmentIdx)` | The single flat pool of all `SegmentIdx` values, owned by the grid. Accessed via `cell_offsets + write_cursor`. |
| `allocator` | `std.mem.Allocator` | Allocator used for all arrays. Stored so that `deinit` can free without needing a parameter. |

**Memory layout.** All arrays are flat slices. The `cell_offsets` and `cell_counts` arrays are sized to `cells_x × cells_y` and indexed by `row * cells_x + col`. This is a row-major 2D layout.

---

### `SpatialGrid.init`

```zig
pub fn init(
    allocator: std.mem.Allocator,
    die_bbox: Rect,
    pdk: *const PdkConfig,
) !SpatialGrid
```

**Purpose.** Allocate and zero-initialize the spatial grid from the die bounding box and PDK configuration.

**Algorithm.**
1. Iterate over all `pdk.num_metal_layers` to find `max_sp = max(pdk.min_spacing[i])`.
2. Compute `cell_size = max(max_sp * 2.0, 0.01)`.
3. Compute `cx = ceil((die_bbox.x2 - die_bbox.x1) / cell_size) + 1` and `cy` similarly.
4. Allocate `cell_offsets` as `[]u32` of length `cx × cy`, zeroed.
5. Allocate `cell_counts` as `[]u16` of length `cx × cy`, zeroed.
6. Initialize `segment_pool` as an empty `ArrayListUnmanaged`.
7. Return the struct. The grid is initially empty — no segments are registered until `rebuild` is called.

**Error.** Returns `error.OutOfMemory` if either allocation fails. Uses `errdefer` to free partial allocations on error.

---

### `SpatialGrid.deinit`

```zig
pub fn deinit(self: *SpatialGrid) void
```

**Purpose.** Free all owned memory.

**Algorithm.** Calls `allocator.free(cell_offsets)`, `allocator.free(cell_counts)`, and `segment_pool.deinit(allocator)`. Does not zero the struct.

---

### `SpatialGrid.cellIndex`

```zig
pub inline fn cellIndex(self: *const SpatialGrid, x: f32, y: f32) u32
```

**Purpose.** Convert world coordinates `(x, y)` to a flat cell index. O(1). Marked `inline` so the computation is inlined at call sites for performance.

**Algorithm.**
1. `fx = max(0.0, (x - origin_x) / cell_size)` — translate and scale, clamp negative to zero.
2. `fy = max(0.0, (y - origin_y) / cell_size)`.
3. `cx = min(intFromFloat(fx), cells_x - 1)` — floor to integer, clamp to last column.
4. `cy = min(intFromFloat(fy), cells_y - 1)` — floor to integer, clamp to last row.
5. Return `cy * cells_x + cx`.

**Clamping.** Negative inputs are clamped to cell 0. Inputs beyond the die edge are clamped to the last cell. This ensures the function never returns an out-of-bounds index.

---

### `SpatialGrid.rebuild`

```zig
pub fn rebuild(
    self: *SpatialGrid,
    x1: []const f32,
    y1: []const f32,
    x2: []const f32,
    y2: []const f32,
    count: u32,
) !void
```

**Purpose.** Populate the grid from a set of `count` segments described by their coordinate arrays. Called between routing wavefronts when the set of placed segments changes. O(n × cells_per_segment).

**Algorithm — three-phase bucket sort:**

**Phase 1: Count.** Zero `cell_counts`. For each segment `i` in `0..count`:
- Compute `min_x = min(x1[i], x2[i])`, `max_x = max(...)`, similarly for Y.
- Compute `cx_lo = cellCol(min_x)`, `cx_hi = cellCol(max_x)`.
- Compute `cy_lo = cellRow(min_y)`, `cy_hi = cellRow(max_y)`.
- For every cell `(cx, cy)` in the box `[cx_lo..cx_hi] × [cy_lo..cy_hi]`, increment `cell_counts[cy * cells_x + cx]` with saturating add.

A segment that is longer than one cell is registered in all cells its bounding box spans. This is conservative but correct: the query will see the segment from any of those cells.

**Phase 2: Prefix sum.** Compute `cell_offsets` as the exclusive prefix sum of `cell_counts`:
```
cell_offsets[0] = 0
cell_offsets[i] = cell_offsets[i-1] + cell_counts[i-1]
total = sum(cell_counts)
```

**Phase 3: Fill pool.** Clear `segment_pool` (retaining capacity). Resize it to `total`. Allocate a temporary `write_cursors[total_cells]` array initialized to zero. For each segment `i`, iterate over its covered cells again and write `SegmentIdx.fromInt(i)` at position `cell_offsets[cell] + write_cursors[cell]`, then increment `write_cursors[cell]`.

The temporary `write_cursors` array is freed after the loop.

**Correctness.** After `rebuild`, for any cell `c`, `segment_pool[cell_offsets[c] .. cell_offsets[c] + cell_counts[c]]` contains exactly the indices of all segments whose bounding boxes overlap cell `c`.

**Complexity.** O(n × average_cells_per_segment). For typical IC segments that are short (1–10 µm) and cells of size ~0.3 µm (2× sky130 M1 spacing of 0.14 µm), most segments span 1–35 cells, giving roughly O(10n) work.

---

### `SpatialGrid.queryNeighborhood`

```zig
pub fn queryNeighborhood(self: *const SpatialGrid, x: f32, y: f32) NeighborIterator
```

**Purpose.** Return an iterator over all segment indices in the 3×3 grid neighborhood centered on the cell containing `(x, y)`. The caller is responsible for performing actual geometry intersection tests against the returned indices.

**Algorithm.** Computes `center_col = cellCol(x)` and `center_row = cellRow(y)`, constructs a `NeighborIterator` with these center coordinates, and returns it without consuming any cells yet (lazy initialization via `started = false`).

---

### `SpatialGrid.cellCol` / `SpatialGrid.cellRow`

```zig
fn cellCol(self: *const SpatialGrid, x: f32) u32
fn cellRow(self: *const SpatialGrid, y: f32) u32
```

**Purpose.** Private helpers used by `rebuild`, `queryNeighborhood`, and `cellIndex`. Convert a single world coordinate to a clamped column or row index.

**Algorithm.** Identical to the corresponding half of `cellIndex`: translate by origin, divide by `cell_size`, floor, clamp to `[0, cells_x - 1]` or `[0, cells_y - 1]`.

---

### `NeighborIterator`

A stateful iterator returned by `queryNeighborhood`. It walks all cells in the 3×3 neighborhood of a center cell and yields each stored `SegmentIdx` in turn.

| Field | Type | Description |
|-------|------|-------------|
| `grid` | `*const SpatialGrid` | Back-reference to the grid being queried. Used to read `cell_offsets`, `cell_counts`, `segment_pool`. |
| `center_col` | `u32` | Column of the center cell. |
| `center_row` | `u32` | Row of the center cell. |
| `dy` | `i8` | Current row offset from center: `−1`, `0`, or `+1`. |
| `dx` | `i8` | Current column offset from center: `−1`, `0`, or `+1`. |
| `seg_idx` | `u16` | Index into the current cell's pool slice (0-based within the cell). |
| `started` | `bool` | `false` until `next()` is called the first time. Allows lazy initialization of `dy`, `dx`, `seg_idx` to their starting values of `−1, −1, 0` on the first call. |

#### `NeighborIterator.next`

```zig
pub fn next(self: *NeighborIterator) ?SegmentIdx
```

**Purpose.** Advance to the next segment index and return it, or return `null` when all 9 cells have been exhausted.

**Algorithm.**
1. On first call (`!started`), set `dy = -1`, `dx = -1`, `seg_idx = 0`, `started = true`.
2. Outer loop: while `dy <= 1`:
   - Compute absolute row `r = center_row + dy`. If `r` is out of bounds, skip to next `dy`.
   - Inner loop: while `dx <= 1`:
     - Compute absolute column `c = center_col + dx`. If out of bounds, advance `dx` and reset `seg_idx`.
     - Compute `cell = r * cells_x + c`.
     - If `seg_idx < cell_counts[cell]`, read and return `segment_pool[cell_offsets[cell] + seg_idx]`, increment `seg_idx`.
     - Otherwise, advance `dx`, reset `seg_idx = 0`.
3. When `dy > 1`, return `null`.

**Subtlety.** The iterator walks cells in column-major order within each row: `(−1,−1), (−1,0), (−1,+1), (0,−1), ...`. Edge cells (where `r` or `c` would be negative or beyond grid dimensions) are skipped by the bounds checks.

**Caller contract.** The caller must perform actual geometry intersection tests. The iterator yields *candidates* — all segments registered in the neighboring cells — not a filtered list. Segments registered in multiple cells due to multi-cell span may be yielded more than once if the query center is near a cell boundary (unlikely but possible). Callers should deduplicate if needed.

---

## `SpatialDrcChecker`

A higher-level struct wrapping `SpatialGrid` with segment geometry, exposing a `checkSpacing` method that returns a combined hard/soft DRC result.

### Fields

| Field | Type | Description |
|-------|------|-------------|
| `grid` | `*const SpatialGrid` | The spatial index to query for candidates. |
| `seg_x1` | `[]const f32` | Start X of each segment, indexed by `SegmentIdx.toInt()`. |
| `seg_y1` | `[]const f32` | Start Y of each segment. |
| `seg_x2` | `[]const f32` | End X of each segment. |
| `seg_y2` | `[]const f32` | End Y of each segment. |
| `seg_width` | `[]const f32` | Physical wire width of each segment, in micrometers. Used to compute the wire's bounding box (half-width expansion). |
| `seg_layer` | `[]const u8` | Metal layer index of each segment. Only segments on the same layer as the query are checked. |
| `seg_net` | `[]const NetIdx` | Net ownership of each segment. Same-net segments are not checked (no same-net DRC). |
| `seg_count` | `u32` | Number of valid segments in the arrays. |
| `pdk` | `*const PdkConfig` | PDK configuration used to look up `min_spacing` and `min_width` per layer. |

### `SpacingResult`

```zig
pub const SpacingResult = struct {
    hard_violation: bool,
    soft_penalty: f32,
};
```

- `hard_violation`: `true` if any nearby segment is within `min_spacing` of the query point (violates the hard DRC rule).
- `soft_penalty`: count of nearby segments that are between `min_spacing` and `1.5 × min_spacing` of the query point. These are proximity warnings, useful as A* soft penalties.

### `SpatialDrcChecker.checkSpacing`

```zig
pub fn checkSpacing(
    self: *const SpatialDrcChecker,
    layer: u8,
    x: f32,
    y: f32,
    net: NetIdx,
) SpacingResult
```

**Purpose.** Check whether placing a via/contact at world position `(layer, x, y)` on net `net` would violate DRC spacing rules against existing segments on the same layer.

**Algorithm.**
1. Look up `min_sp = pdk.min_spacing[pdk_idx]` and `min_w = pdk.min_width[pdk_idx]`, where `pdk_idx = max(0, layer - 1)`. The `-1` offset arises from the convention that layer 1 = Met1, layer 0 = Li.
2. Compute the query bounding box: the new via has half-width `hw = min_w / 2`, so the bbox is `[x - hw, x + hw] × [y - hw, y + hw]`.
3. Query the spatial grid via `grid.queryNeighborhood(x, y)` to get candidate segment indices.
4. For each candidate:
   - Skip if `seg_layer[si] != layer` (different layer — no DRC interaction).
   - Skip if `seg_net[si] == net` (same net — no DRC for same-net wire touching).
   - Compute the candidate segment's bounding box: expand the segment's AABB by `seg_width[si] / 2` on each side.
   - Compute the gap as `max(gap_x, gap_y)` where `gap_x = max(px_min - sx_max, sx_min - px_max)` and similarly for Y. This is the Chebyshev (L∞) gap between the two bounding boxes.
   - If `gap < 0` (overlap) or `gap < min_sp`: set `hard = true`, break immediately.
   - Else if `gap < min_sp * 1.5`: increment `soft += 1.0`.
5. Return `{ .hard_violation = hard, .soft_penalty = soft }`.

**Gap formula.** The one-dimensional gap between intervals `[a, b]` and `[c, d]` is `max(a - d, c - b)`. Positive gap = clearance; zero = touching; negative = overlap. The 2D gap between two bounding boxes is the maximum of the X and Y gaps (L∞ metric), which gives the correct DRC check for rectangular wires.

---

## Tests

Eight tests cover all major code paths:

| Test | What it verifies |
|------|-----------------|
| `SpatialGrid init and deinit` | Grid is created from sky130 PDK without crash; `cells_x > 0`, `cells_y > 0`. |
| `SpatialGrid cellIndex basic` | Origin maps to index 0; moving one cell right adds 1; moving one cell up adds `cells_x`. |
| `SpatialGrid cellIndex clamps out-of-bounds` | Negative coords clamp to 0; large coords clamp to last cell. |
| `SpatialGrid rebuild preserves all segments` | 100 diagonal segments are inserted; each is findable by querying its midpoint. |
| `SpatialGrid empty query returns nothing` | Empty grid returns `null` on first `next()`. |
| `SpatialGrid query finds segment at exact coordinate` | One segment at `(15, 15)–(35, 15)`; querying at `(25, 15)` finds it. |
| `SpatialGrid segment spanning multiple cells` | One segment spanning 5 cells is findable from any of those cells. |
| `SpatialDrcChecker no violation far away` | One segment at `(10,10)–(20,10)`; checking at `(50, 50)` on a different net finds no violations. |

---

## Spatial Grid Visualization

```svg
<svg viewBox="0 0 800 500" xmlns="http://www.w3.org/2000/svg" font-family="'Inter', 'Segoe UI', sans-serif">
  <!-- Background -->
  <rect width="800" height="500" fill="#060C18"/>

  <!-- Title -->
  <text x="400" y="32" text-anchor="middle" fill="#B8D0E8" font-size="16" font-weight="600">SpatialGrid — Uniform 2D Index for O(1) Segment Lookup</text>

  <!-- Grid cells (10x8 grid representing the die) -->
  <!-- Base grid lines -->
  <g stroke="#14263E" stroke-width="0.8" fill="none">
    <!-- Vertical lines -->
    <line x1="60" y1="60" x2="60" y2="420"/>
    <line x1="120" y1="60" x2="120" y2="420"/>
    <line x1="180" y1="60" x2="180" y2="420"/>
    <line x1="240" y1="60" x2="240" y2="420"/>
    <line x1="300" y1="60" x2="300" y2="420"/>
    <line x1="360" y1="60" x2="360" y2="420"/>
    <line x1="420" y1="60" x2="420" y2="420"/>
    <line x1="480" y1="60" x2="480" y2="420"/>
    <line x1="540" y1="60" x2="540" y2="420"/>
    <line x1="600" y1="60" x2="600" y2="420"/>
    <!-- Horizontal lines -->
    <line x1="60" y1="60" x2="600" y2="60"/>
    <line x1="60" y1="115" x2="600" y2="115"/>
    <line x1="60" y1="170" x2="600" y2="170"/>
    <line x1="60" y1="225" x2="600" y2="225"/>
    <line x1="60" y1="280" x2="600" y2="280"/>
    <line x1="60" y1="335" x2="600" y2="335"/>
    <line x1="60" y1="390" x2="600" y2="390"/>
    <line x1="60" y1="420" x2="600" y2="420"/>
  </g>

  <!-- Column/row labels -->
  <text x="90" y="54" text-anchor="middle" fill="#3E5E80" font-size="9">c0</text>
  <text x="150" y="54" text-anchor="middle" fill="#3E5E80" font-size="9">c1</text>
  <text x="210" y="54" text-anchor="middle" fill="#3E5E80" font-size="9">c2</text>
  <text x="270" y="54" text-anchor="middle" fill="#3E5E80" font-size="9">c3</text>
  <text x="330" y="54" text-anchor="middle" fill="#3E5E80" font-size="9">c4</text>
  <text x="390" y="54" text-anchor="middle" fill="#3E5E80" font-size="9">c5</text>
  <text x="450" y="54" text-anchor="middle" fill="#3E5E80" font-size="9">c6</text>
  <text x="510" y="54" text-anchor="middle" fill="#3E5E80" font-size="9">c7</text>
  <text x="570" y="54" text-anchor="middle" fill="#3E5E80" font-size="9">c8</text>

  <text x="48" y="94" text-anchor="middle" fill="#3E5E80" font-size="9">r0</text>
  <text x="48" y="148" text-anchor="middle" fill="#3E5E80" font-size="9">r1</text>
  <text x="48" y="203" text-anchor="middle" fill="#3E5E80" font-size="9">r2</text>
  <text x="48" y="258" text-anchor="middle" fill="#3E5E80" font-size="9">r3</text>
  <text x="48" y="313" text-anchor="middle" fill="#3E5E80" font-size="9">r4</text>
  <text x="48" y="368" text-anchor="middle" fill="#3E5E80" font-size="9">r5</text>
  <text x="48" y="410" text-anchor="middle" fill="#3E5E80" font-size="9">r6</text>

  <!-- Segment A: horizontal wire in cells (c2,r2)-(c5,r2) -->
  <line x1="195" y1="202" x2="405" y2="202" stroke="#1E88E5" stroke-width="3" stroke-linecap="round"/>
  <text x="300" y="196" text-anchor="middle" fill="#1E88E5" font-size="9">seg[0] Met1</text>

  <!-- Segment A's cells highlighted (c2..c5, r2) -->
  <rect x="180" y="170" width="60" height="55" fill="#1E88E5" fill-opacity="0.12" stroke="#1E88E5" stroke-width="1"/>
  <rect x="240" y="170" width="60" height="55" fill="#1E88E5" fill-opacity="0.12" stroke="#1E88E5" stroke-width="1"/>
  <rect x="300" y="170" width="60" height="55" fill="#1E88E5" fill-opacity="0.12" stroke="#1E88E5" stroke-width="1"/>
  <rect x="360" y="170" width="60" height="55" fill="#1E88E5" fill-opacity="0.12" stroke="#1E88E5" stroke-width="1"/>

  <!-- Segment B: shorter wire in cells (c6,r3)-(c7,r4) diagonal device outline -->
  <rect x="450" y="258" width="90" height="75" fill="none" stroke="#43A047" stroke-width="2" stroke-dasharray="4,2"/>
  <text x="495" y="300" text-anchor="middle" fill="#43A047" font-size="9">device[3]</text>
  <!-- Cells containing device outline -->
  <rect x="420" y="225" width="60" height="55" fill="#43A047" fill-opacity="0.10" stroke="#43A047" stroke-width="0.8"/>
  <rect x="480" y="225" width="60" height="55" fill="#43A047" fill-opacity="0.10" stroke="#43A047" stroke-width="0.8"/>
  <rect x="540" y="225" width="60" height="55" fill="#43A047" fill-opacity="0.10" stroke="#43A047" stroke-width="0.8"/>
  <rect x="420" y="280" width="60" height="55" fill="#43A047" fill-opacity="0.10" stroke="#43A047" stroke-width="0.8"/>
  <rect x="480" y="280" width="60" height="55" fill="#43A047" fill-opacity="0.10" stroke="#43A047" stroke-width="0.8"/>
  <rect x="540" y="280" width="60" height="55" fill="#43A047" fill-opacity="0.10" stroke="#43A047" stroke-width="0.8"/>

  <!-- Query point at (c4, r3) -->
  <circle cx="345" cy="260" r="6" fill="#00C4E8" stroke="#FFFFFF" stroke-width="1.5"/>
  <text x="345" y="248" text-anchor="middle" fill="#00C4E8" font-size="9" font-weight="600">query(x,y)</text>

  <!-- 3×3 neighborhood highlight around (c4, r3) -->
  <rect x="240" y="225" width="180" height="165" fill="none" stroke="#00C4E8" stroke-width="2" stroke-dasharray="6,3"/>
  <text x="330" y="406" text-anchor="middle" fill="#00C4E8" font-size="9">3×3 neighborhood</text>
  <!-- Cells within 3x3 -->
  <rect x="240" y="225" width="60" height="55" fill="#00C4E8" fill-opacity="0.08"/>
  <rect x="300" y="225" width="60" height="55" fill="#00C4E8" fill-opacity="0.08"/>
  <rect x="360" y="225" width="60" height="55" fill="#00C4E8" fill-opacity="0.08"/>
  <rect x="240" y="280" width="60" height="55" fill="#00C4E8" fill-opacity="0.08"/>
  <rect x="300" y="280" width="60" height="55" fill="#00C4E8" fill-opacity="0.08"/>
  <rect x="360" y="280" width="60" height="55" fill="#00C4E8" fill-opacity="0.08"/>
  <rect x="240" y="335" width="60" height="55" fill="#00C4E8" fill-opacity="0.08"/>
  <rect x="300" y="335" width="60" height="55" fill="#00C4E8" fill-opacity="0.08"/>
  <rect x="360" y="335" width="60" height="55" fill="#00C4E8" fill-opacity="0.08"/>

  <!-- segment_pool diagram (right side) -->
  <g transform="translate(630, 60)">
    <text x="0" y="0" fill="#B8D0E8" font-size="11" font-weight="600">segment_pool[]</text>
    <text x="0" y="15" fill="#3E5E80" font-size="8">flat SegmentIdx array</text>

    <!-- cell_offsets[c2r2] -->
    <rect x="0" y="24" width="100" height="20" fill="#0A1E30" stroke="#14263E"/>
    <text x="50" y="37" text-anchor="middle" fill="#1E88E5" font-size="9">off=0  cnt=1</text>
    <text x="-2" y="37" text-anchor="end" fill="#3E5E80" font-size="8">c2r2</text>

    <rect x="0" y="44" width="100" height="20" fill="#0A1E30" stroke="#14263E"/>
    <text x="50" y="57" text-anchor="middle" fill="#1E88E5" font-size="9">off=1  cnt=1</text>
    <text x="-2" y="57" text-anchor="end" fill="#3E5E80" font-size="8">c3r2</text>

    <rect x="0" y="64" width="100" height="20" fill="#0A1E30" stroke="#14263E"/>
    <text x="50" y="77" text-anchor="middle" fill="#1E88E5" font-size="9">off=2  cnt=1</text>
    <text x="-2" y="77" text-anchor="end" fill="#3E5E80" font-size="8">c4r2</text>

    <rect x="0" y="84" width="100" height="20" fill="#0A1E30" stroke="#14263E"/>
    <text x="50" y="97" text-anchor="middle" fill="#1E88E5" font-size="9">off=3  cnt=1</text>
    <text x="-2" y="97" text-anchor="end" fill="#3E5E80" font-size="8">c5r2</text>

    <text x="50" y="120" text-anchor="middle" fill="#3E5E80" font-size="8">... empty cells ...</text>

    <!-- Pool values -->
    <text x="0" y="140" fill="#B8D0E8" font-size="10" font-weight="600">pool items</text>
    <rect x="0" y="146" width="25" height="20" fill="#1E88E5" fill-opacity="0.3" stroke="#1E88E5"/>
    <text x="12" y="159" text-anchor="middle" fill="#B8D0E8" font-size="9">0</text>
    <rect x="25" y="146" width="25" height="20" fill="#1E88E5" fill-opacity="0.3" stroke="#1E88E5"/>
    <text x="37" y="159" text-anchor="middle" fill="#B8D0E8" font-size="9">0</text>
    <rect x="50" y="146" width="25" height="20" fill="#1E88E5" fill-opacity="0.3" stroke="#1E88E5"/>
    <text x="62" y="159" text-anchor="middle" fill="#B8D0E8" font-size="9">0</text>
    <rect x="75" y="146" width="25" height="20" fill="#1E88E5" fill-opacity="0.3" stroke="#1E88E5"/>
    <text x="87" y="159" text-anchor="middle" fill="#B8D0E8" font-size="9">0</text>
    <text x="50" y="180" text-anchor="middle" fill="#3E5E80" font-size="8">SegmentIdx = 0 (seg[0])</text>
  </g>

  <!-- Legend -->
  <rect x="62" y="432" width="14" height="8" fill="#1E88E5" fill-opacity="0.3" stroke="#1E88E5"/>
  <text x="82" y="440" fill="#B8D0E8" font-size="9">Met1 segment cells</text>
  <rect x="182" y="432" width="14" height="8" fill="#43A047" fill-opacity="0.3" stroke="#43A047"/>
  <text x="202" y="440" fill="#B8D0E8" font-size="9">Device outline cells</text>
  <rect x="312" y="432" width="14" height="8" fill="#00C4E8" fill-opacity="0.3" stroke="#00C4E8"/>
  <text x="332" y="440" fill="#B8D0E8" font-size="9">Query neighborhood (returned by iterator)</text>

  <!-- Source label -->
  <text x="330" y="478" text-anchor="middle" fill="#3E5E80" font-size="9">src/router/spatial_grid.zig — cell_size = 2×max(min_spacing) — O(1) cellIndex, O(9k) queryNeighborhood</text>
</svg>
```

---

## Memory Layout and Allocation Strategy

All arrays are allocated as contiguous flat slices:

- `cell_offsets [cells_x × cells_y × 4 bytes]`
- `cell_counts  [cells_x × cells_y × 2 bytes]`
- `segment_pool [dynamic — total registrations × 4 bytes]`

For a typical design (1000 µm² die, sky130 at `cell_size = 0.28 µm`):
- Grid dimensions: ~3572 × 3572 cells ≈ 12.75M cells
- `cell_offsets`: ~51 MB
- `cell_counts`: ~25 MB
- Total: ~76 MB for the index alone

In practice, designs are smaller (100–200 µm²) and cells have few entries, so memory is not an issue.

The `segment_pool` is a `std.ArrayListUnmanaged` which grows geometrically. After `rebuild`, its capacity is exactly `total_registrations` (no overallocation beyond what `resize` produces).

---

## Summary of All Types and Functions

| Symbol | Kind | Summary |
|--------|------|---------|
| `SpatialGrid` | struct | Uniform 2D grid index over segment bounding boxes |
| `SpatialGrid.init` | fn | Allocate from die bbox + PDK; compute cell_size |
| `SpatialGrid.deinit` | fn | Free all arrays |
| `SpatialGrid.cellIndex` | inline fn | O(1) world→flat-cell-index |
| `SpatialGrid.rebuild` | fn | 3-phase bucket sort; O(n×avg_cells) |
| `SpatialGrid.queryNeighborhood` | fn | Return NeighborIterator for 3×3 neighborhood |
| `SpatialGrid.cellCol` | private fn | World X → clamped column index |
| `SpatialGrid.cellRow` | private fn | World Y → clamped row index |
| `NeighborIterator` | struct | Stateful iterator over 3×3 neighborhood |
| `NeighborIterator.next` | fn | Advance; returns `?SegmentIdx` |
| `SpatialDrcChecker` | struct | Grid + geometry arrays → `checkSpacing` |
| `SpatialDrcChecker.checkSpacing` | fn | Returns hard/soft DRC result at (layer, x, y) |
| `SpacingResult` | struct | `{hard_violation: bool, soft_penalty: f32}` |
