# Thermal Routing

## What Thermal Routing Means in IC Layout

In any integrated circuit, devices dissipate power as heat. A power transistor running at high current, a bandgap reference biased near its rated current, or a resistor network with significant voltage drop all generate heat that spreads outward through the silicon substrate, metal layers, and package. That heat creates spatial temperature gradients across the die.

For digital circuits this is largely irrelevant at the net-routing level. For analog circuits it is critical. The threshold voltage `Vth`, carrier mobility `µ`, resistor sheet resistance, and bipolar `Vbe` of every transistor are functions of temperature. If two matched transistors — say the two halves of a differential pair — sit at different temperatures, they exhibit different electrical characteristics and the matching is degraded. A 5 °C difference can introduce mV-scale `Vos` in a precision amplifier.

Thermal routing addresses this at three levels:

1. **Hotspot avoidance.** Long, wide power-rail wires should not be routed over or between matched analog devices, because metal traces conduct heat and increase the thermal coupling from hot regions to sensitive devices.

2. **Isotherm-following routing.** Matched net pairs (differential pair, current mirror legs) should be routed along the same isotherm — the curve of constant temperature — so that both paths see the same temperature profile and therefore the same parasitic resistance per unit length.

3. **Thermal cost in A*.** When the matched router searches for a path using A*, it queries the thermal map and adds a cost proportional to the temperature difference between consecutive grid nodes. This steers routes toward same-temperature corridors.

---

## Source File

`src/router/thermal.zig` — 99 lines. There is no `thermal/` subdirectory; all thermal code is in this single file.

---

## Data Structures

### `Rect`

```zig
pub const Rect = struct {
    x1: f32, y1: f32, x2: f32, y2: f32,
    pub fn width(self: Rect) f32 { return self.x2 - self.x1; }
    pub fn height(self: Rect) f32 { return self.y2 - self.y1; }
};
```

A simple axis-aligned bounding box used to describe the die extent. `width()` and `height()` are inline helpers for computing grid dimensions. Both return `f32` in micrometers.

### `ThermalMap`

The central data structure. A uniform 2D grid of `f32` temperatures stored in row-major order.

| Field | Type | Description |
|-------|------|-------------|
| `allocator` | `std.mem.Allocator` | Allocator that owns the `temps` slice. Used in `deinit`. |
| `temps` | `[]f32` | Flat row-major array of `rows × cols` temperature values, in degrees Celsius. Index formula: `row * cols + col`. Initially filled with `ambient`. |
| `rows` | `u32` | Number of grid rows (Y divisions). Computed as `ceil(bbox.height() / cell_size)`. |
| `cols` | `u32` | Number of grid columns (X divisions). Computed as `ceil(bbox.width() / cell_size)`. |
| `cell_size` | `f32` | Physical size of one grid cell in micrometers. Passed in at construction time and used for all coordinate-to-index conversions. |
| `bbox_x1` | `f32` | Die bounding box left edge (min X), in micrometers. |
| `bbox_y1` | `f32` | Die bounding box bottom edge (min Y), in micrometers. |
| `bbox_x2` | `f32` | Die bounding box right edge (max X), in micrometers. |
| `bbox_y2` | `f32` | Die bounding box top edge (max Y), in micrometers. |
| `ambient` | `f32` | Ambient (background) temperature in degrees Celsius. Default is `25.0`. All cells are initialized to this value. Queries outside the bounding box also return this value. |

The `temps` array is indexed as `temps[row * cols + col]` where `row = 0` is the bottom of the die (min Y) and `col = 0` is the left (min X). This matches the way A* iterates over a grid.

---

## Functions

### `ThermalMap.init`

```zig
pub fn init(
    allocator: std.mem.Allocator,
    bbox: Rect,
    cell_size: f32,
    ambient: f32,
) !ThermalMap
```

**Purpose.** Allocates and initializes the thermal grid.

**Algorithm.**
1. Compute `cols = ceil(bbox.width() / cell_size)` using `@ceil` followed by `@intFromFloat`.
2. Compute `rows = ceil(bbox.height() / cell_size)`.
3. Allocate `temps` as a flat slice of `cols * rows` `f32` values.
4. Fill the entire slice with `ambient` using `@memset`.
5. Store all fields and return.

**Return.** `!ThermalMap` — returns `error.OutOfMemory` if the allocator fails.

**Notes.** The `cell_size` should be chosen to give adequate spatial resolution without consuming excessive memory. For a 1 mm² die with `cell_size = 10 µm`, the grid is `100 × 100 = 10 000` cells = 40 KB of `f32`. For higher precision routing, `cell_size = 1 µm` gives a 1 MB grid — still small.

---

### `ThermalMap.deinit`

```zig
pub fn deinit(self: *ThermalMap) void
```

**Purpose.** Frees the `temps` slice. Must be called when the `ThermalMap` is no longer needed.

**Algorithm.** Calls `self.allocator.free(self.temps)`. Does not zero out or invalidate the struct.

---

### `ThermalMap.query`

```zig
pub fn query(self: *const ThermalMap, x: f32, y: f32) f32
```

**Purpose.** Returns the temperature at world coordinate `(x, y)` in degrees Celsius. O(1).

**Algorithm.**
1. Check if `(x, y)` is outside the bounding box `[bbox_x1, bbox_x2] × [bbox_y1, bbox_y2]`. If so, return `self.ambient` immediately — no crash on out-of-bounds queries.
2. Compute `col = clamp(floor((x - bbox_x1) / cell_size), 0, cols - 1)` using `@intFromFloat` after the division, then `@min/@max` clamping.
3. Compute `row = clamp(floor((y - bbox_y1) / cell_size), 0, rows - 1)` by the same method.
4. Return `self.temps[row * self.cols + col]`.

**Complexity.** O(1) — pure arithmetic and array index.

**Edge cases.**
- Coordinates exactly on the boundary land in the adjacent cell (floor rounding) or are clamped.
- Negative coordinates return `ambient`.
- Coordinates beyond `bbox_x2` or `bbox_y2` are caught by the bounds check.

---

### `ThermalMap.addHotspot`

```zig
pub fn addHotspot(
    self: *ThermalMap,
    x: f32,
    y: f32,
    delta_T: f32,
    radius: f32,
) !void
```

**Purpose.** Models a heat-generating device at world position `(x, y)` by adding a Gaussian temperature distribution to all cells within `radius` micrometers. The peak temperature increase at `(x, y)` is `delta_T` degrees Celsius.

**Algorithm — zero-radius case (`radius <= 0`):**
1. Convert `(x, y)` to a single grid cell (col, row) using the same formula as `query`.
2. Clamp the cell indices to valid ranges.
3. Directly add `delta_T` to `temps[row * cols + col]`.
4. Return immediately.

**Algorithm — non-zero radius:**
1. Compute the floating-point center coordinates: `cc = (x - bbox_x1) / cell_size`, `cr = (y - bbox_y1) / cell_size`.
2. Compute the floating-point radius in cell units: `rf = radius / cell_size`.
3. Compute the integer bounding box of affected cells:
   - `cmin = max(0, floor(cc - rf))`, `cmax = min(cols-1, ceil(cc + rf))`
   - `rmin = max(0, floor(cr - rf))`, `rmax = min(rows-1, ceil(cr + rf))`
4. Compute the variance for the Gaussian: `sigma_sq = 2.0 * radius * radius`. This is `2σ²` where `σ = radius` in micrometers.
5. Iterate over all cells in the bounding box `[rmin..rmax] × [cmin..cmax]`:
   - Compute the physical center of each cell: `cx = bbox_x1 + (col + 0.5) * cell_size`, `cy = bbox_y1 + (row + 0.5) * cell_size`.
   - Compute the squared Euclidean distance from the hotspot: `dx = cx - x`, `dy = cy - y`.
   - Compute the Gaussian influence: `inf = delta_T * exp(-(dx² + dy²) / sigma_sq)`.
   - Add `inf` to `temps[row * cols + col]`.
6. The implementation uses a double `while` loop with manual bounds checking (`if (row_i >= rows or col_i >= cols) continue`) to handle edge cells safely.

**Thermal model.** The Gaussian kernel is the natural solution to the 2D heat diffusion equation in a homogeneous medium for a point source at steady state. The `sigma_sq = 2 * radius²` parameterization means the influence drops to `exp(-0.5) ≈ 60.7%` at `r = radius`, and to `exp(-2) ≈ 13.5%` at `r = 2 * radius`. This is an approximation; real silicon has anisotropic thermal conductivity and layered thermal resistance from metal, oxide, and substrate.

**Error return.** The signature includes `!void` to match async/arena patterns, but the current implementation does not allocate — the `!` is present for forward compatibility (the spec mentions `extractIsotherm` which would need allocation).

---

## Integration with the Matched Router

`matched_router.zig` imports `thermal.zig` directly:

```zig
const thermal = @import("thermal.zig");
```

The `MatchedRouter` struct holds an optional reference:

```zig
thermal_map: ?*const thermal.ThermalMap,
```

When `routeGroup` is called, the caller passes a `?*const thermal.ThermalMap`:

```zig
pub fn routeGroup(
    self: *MatchedRouter,
    grid: *const MultiLayerGrid,
    net_p: NetIdx,
    net_n: NetIdx,
    pins_p: []const [2]f32,
    pins_n: []const [2]f32,
    tm: ?*const thermal.ThermalMap,
) !void
```

The thermal map is stored in `self.thermal_map = tm`. The cost function in `MatchedRoutingCost` is designed to incorporate thermal penalties: when evaluating candidate nodes during A* expansion, the router queries `thermal_map.query(x, y)` for the candidate position and the current position, computes `|T_candidate - T_current|`, and adds it (scaled by a weight) to the movement cost. This steers both the `+` and `−` branches of a differential pair along the same isotherm.

The `MatchedRoutingCost` struct:

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `base_cost` | `f32` | `1.0` | Base movement cost per grid step |
| `mismatch_penalty` | `f32` | `10.0` | Penalty per unit of wire-length mismatch between paired nets |
| `via_penalty` | `f32` | `2.0` | Cost per via insertion |
| `same_layer_bonus` | `f32` | `-0.5` | Negative cost (bonus) for staying on the preferred layer |
| `preferred_layer` | `u8` | `1` | Layer index to favor |

The thermal penalty is applied on top of these costs, with its weight configurable in the spec as `1.0` by default.

---

## Tests

Three tests are included inline in `thermal.zig`:

### `test "ThermalMap query returns ambient"`

Creates a 100 µm × 100 µm map with `cell_size = 10 µm`, `ambient = 25.0`. Queries `(50, 50)`. Asserts the result equals `25.0` exactly (no hotspots added, so all cells remain at ambient).

### `test "ThermalMap hotspot raises temperature"`

Creates the same map. Calls `addHotspot(50.0, 50.0, 10.0, 20.0)` — a 10 °C hotspot at the center with 20 µm radius. Queries `(50, 50)` and asserts the result is strictly greater than `25.0`. This verifies that the Gaussian kernel adds nonzero heat to the cell containing the hotspot center.

### `test "ThermalMap query OOB returns ambient"`

Creates the same map, adds no hotspot. Queries `(-1.0, 50.0)` — one micrometer to the left of the die edge. Asserts the result equals `25.0`. This verifies the out-of-bounds guard in `query`.

---

## Thermal Map Visualization

```svg
<svg viewBox="0 0 900 600" xmlns="http://www.w3.org/2000/svg" font-family="'Inter', 'Segoe UI', sans-serif">
  <!-- Background -->
  <rect width="900" height="600" fill="#060C18"/>

  <!-- Title -->
  <text x="450" y="36" text-anchor="middle" fill="#B8D0E8" font-size="18" font-weight="600">Thermal Map — Isotherm-Aware Analog Routing</text>

  <!-- Die outline -->
  <rect x="60" y="60" width="580" height="460" fill="none" stroke="#14263E" stroke-width="2"/>

  <!-- Grid cells - cool (bottom-left region) -->
  <!-- Row 0 (bottom) cols 0-2 -->
  <rect x="60" y="460" width="58" height="58" fill="#060C18" stroke="#0A1528" stroke-width="0.5"/>
  <rect x="118" y="460" width="58" height="58" fill="#071122" stroke="#0A1528" stroke-width="0.5"/>
  <rect x="176" y="460" width="58" height="58" fill="#08162A" stroke="#0A1528" stroke-width="0.5"/>
  <rect x="234" y="460" width="58" height="58" fill="#091C32" stroke="#0A1528" stroke-width="0.5"/>
  <rect x="292" y="460" width="58" height="58" fill="#0A2038" stroke="#0A1528" stroke-width="0.5"/>
  <rect x="350" y="460" width="58" height="58" fill="#0C263E" stroke="#0A1528" stroke-width="0.5"/>
  <rect x="408" y="460" width="58" height="58" fill="#102C44" stroke="#0A1528" stroke-width="0.5"/>
  <rect x="466" y="460" width="58" height="58" fill="#163345" stroke="#0A1528" stroke-width="0.5"/>
  <rect x="524" y="460" width="58" height="58" fill="#1C3A48" stroke="#0A1528" stroke-width="0.5"/>
  <rect x="582" y="460" width="58" height="58" fill="#22404A" stroke="#0A1528" stroke-width="0.5"/>

  <!-- Row 1 -->
  <rect x="60" y="402" width="58" height="58" fill="#071122" stroke="#0A1528" stroke-width="0.5"/>
  <rect x="118" y="402" width="58" height="58" fill="#091C32" stroke="#0A1528" stroke-width="0.5"/>
  <rect x="176" y="402" width="58" height="58" fill="#0D2238" stroke="#0A1528" stroke-width="0.5"/>
  <rect x="234" y="402" width="58" height="58" fill="#142A44" stroke="#0A1528" stroke-width="0.5"/>
  <rect x="292" y="402" width="58" height="58" fill="#1C3850" stroke="#0A1528" stroke-width="0.5"/>
  <rect x="350" y="402" width="58" height="58" fill="#244258" stroke="#0A1528" stroke-width="0.5"/>
  <rect x="408" y="402" width="58" height="58" fill="#2C4C62" stroke="#0A1528" stroke-width="0.5"/>
  <rect x="466" y="402" width="58" height="58" fill="#345665" stroke="#0A1528" stroke-width="0.5"/>
  <rect x="524" y="402" width="58" height="58" fill="#3C5E68" stroke="#0A1528" stroke-width="0.5"/>
  <rect x="582" y="402" width="58" height="58" fill="#44646A" stroke="#0A1528" stroke-width="0.5"/>

  <!-- Row 2 -->
  <rect x="60" y="344" width="58" height="58" fill="#08162A" stroke="#0A1528" stroke-width="0.5"/>
  <rect x="118" y="344" width="58" height="58" fill="#0D2238" stroke="#0A1528" stroke-width="0.5"/>
  <rect x="176" y="344" width="58" height="58" fill="#162E48" stroke="#0A1528" stroke-width="0.5"/>
  <rect x="234" y="344" width="58" height="58" fill="#243C5A" stroke="#0A1528" stroke-width="0.5"/>
  <rect x="292" y="344" width="58" height="58" fill="#344E6C" stroke="#0A1528" stroke-width="0.5"/>
  <rect x="350" y="344" width="58" height="58" fill="#465E7A" stroke="#0A1528" stroke-width="0.5"/>
  <rect x="408" y="344" width="58" height="58" fill="#586E88" stroke="#0A1528" stroke-width="0.5"/>
  <rect x="466" y="344" width="58" height="58" fill="#6A7E96" stroke="#0A1528" stroke-width="0.5"/>
  <rect x="524" y="344" width="58" height="58" fill="#7C8EA4" stroke="#0A1528" stroke-width="0.5"/>
  <rect x="582" y="344" width="58" height="58" fill="#8E9EB0" stroke="#0A1528" stroke-width="0.5"/>

  <!-- Row 3 — warming toward center-top -->
  <rect x="60" y="286" width="58" height="58" fill="#091C32" stroke="#0A1528" stroke-width="0.5"/>
  <rect x="118" y="286" width="58" height="58" fill="#142A44" stroke="#0A1528" stroke-width="0.5"/>
  <rect x="176" y="286" width="58" height="58" fill="#243C5A" stroke="#0A1528" stroke-width="0.5"/>
  <rect x="234" y="286" width="58" height="58" fill="#3A5272" stroke="#0A1528" stroke-width="0.5"/>
  <rect x="292" y="286" width="58" height="58" fill="#5A7090" stroke="#0A1528" stroke-width="0.5"/>
  <rect x="350" y="286" width="58" height="58" fill="#7E90A8" stroke="#0A1528" stroke-width="0.5"/>
  <rect x="408" y="286" width="58" height="58" fill="#A0A8BC" stroke="#0A1528" stroke-width="0.5"/>
  <rect x="466" y="286" width="58" height="58" fill="#B8B4C4" stroke="#0A1528" stroke-width="0.5"/>
  <rect x="524" y="286" width="58" height="58" fill="#CEC0CC" stroke="#0A1528" stroke-width="0.5"/>
  <rect x="582" y="286" width="58" height="58" fill="#E0CCD0" stroke="#0A1528" stroke-width="0.5"/>

  <!-- Row 4 -->
  <rect x="60" y="228" width="58" height="58" fill="#0C263E" stroke="#0A1528" stroke-width="0.5"/>
  <rect x="118" y="228" width="58" height="58" fill="#1C3850" stroke="#0A1528" stroke-width="0.5"/>
  <rect x="176" y="228" width="58" height="58" fill="#344E6C" stroke="#0A1528" stroke-width="0.5"/>
  <rect x="234" y="228" width="58" height="58" fill="#5A7090" stroke="#0A1528" stroke-width="0.5"/>
  <rect x="292" y="228" width="58" height="58" fill="#8C9CB0" stroke="#0A1528" stroke-width="0.5"/>
  <rect x="350" y="228" width="58" height="58" fill="#C0B880" stroke="#0A1528" stroke-width="0.5"/>
  <rect x="408" y="228" width="58" height="58" fill="#E4C860" stroke="#0A1528" stroke-width="0.5"/>
  <rect x="466" y="228" width="58" height="58" fill="#F0B840" stroke="#0A1528" stroke-width="0.5"/>
  <rect x="524" y="228" width="58" height="58" fill="#E8A838" stroke="#0A1528" stroke-width="0.5"/>
  <rect x="582" y="228" width="58" height="58" fill="#D89830" stroke="#0A1528" stroke-width="0.5"/>

  <!-- Row 5 — hot zone -->
  <rect x="60" y="170" width="58" height="58" fill="#102C44" stroke="#0A1528" stroke-width="0.5"/>
  <rect x="118" y="170" width="58" height="58" fill="#244258" stroke="#0A1528" stroke-width="0.5"/>
  <rect x="176" y="170" width="58" height="58" fill="#465E7A" stroke="#0A1528" stroke-width="0.5"/>
  <rect x="234" y="170" width="58" height="58" fill="#7E90A8" stroke="#0A1528" stroke-width="0.5"/>
  <rect x="292" y="170" width="58" height="58" fill="#C0B880" stroke="#0A1528" stroke-width="0.5"/>

  <!-- Power transistor hot cell -->
  <rect x="350" y="170" width="58" height="58" fill="#EF5350" stroke="#FF6B6B" stroke-width="1.5"/>
  <rect x="408" y="170" width="58" height="58" fill="#F06030" stroke="#0A1528" stroke-width="0.5"/>
  <rect x="466" y="170" width="58" height="58" fill="#E08030" stroke="#0A1528" stroke-width="0.5"/>
  <rect x="524" y="170" width="58" height="58" fill="#C87020" stroke="#0A1528" stroke-width="0.5"/>
  <rect x="582" y="170" width="58" height="58" fill="#B06018" stroke="#0A1528" stroke-width="0.5"/>

  <!-- Row 6 (top) -->
  <rect x="60" y="112" width="58" height="58" fill="#163345" stroke="#0A1528" stroke-width="0.5"/>
  <rect x="118" y="112" width="58" height="58" fill="#2C4C62" stroke="#0A1528" stroke-width="0.5"/>
  <rect x="176" y="112" width="58" height="58" fill="#586E88" stroke="#0A1528" stroke-width="0.5"/>
  <rect x="234" y="112" width="58" height="58" fill="#A0A8BC" stroke="#0A1528" stroke-width="0.5"/>
  <rect x="292" y="112" width="58" height="58" fill="#E4C860" stroke="#0A1528" stroke-width="0.5"/>
  <rect x="350" y="112" width="58" height="58" fill="#FB8C00" stroke="#0A1528" stroke-width="0.5"/>
  <rect x="408" y="112" width="58" height="58" fill="#E08030" stroke="#0A1528" stroke-width="0.5"/>
  <rect x="466" y="112" width="58" height="58" fill="#C07020" stroke="#0A1528" stroke-width="0.5"/>
  <rect x="524" y="112" width="58" height="58" fill="#A86018" stroke="#0A1528" stroke-width="0.5"/>
  <rect x="582" y="112" width="58" height="58" fill="#904E10" stroke="#0A1528" stroke-width="0.5"/>

  <!-- Power transistor label -->
  <text x="379" y="198" text-anchor="middle" fill="#FFFFFF" font-size="9" font-weight="700">PWR</text>
  <text x="379" y="209" text-anchor="middle" fill="#FFFFFF" font-size="9" font-weight="700">NMOS</text>
  <text x="379" y="220" text-anchor="middle" fill="#FFDDDD" font-size="8">95°C</text>

  <!-- Temperature labels on key cells -->
  <text x="89" y="493" text-anchor="middle" fill="#3E5E80" font-size="8">25°C</text>
  <text x="611" y="493" text-anchor="middle" fill="#4A7080" font-size="8">30°C</text>
  <text x="611" y="319" text-anchor="middle" fill="#8A9EA8" font-size="8">45°C</text>
  <text x="379" y="259" text-anchor="middle" fill="#F0D080" font-size="8">72°C</text>
  <text x="379" y="141" text-anchor="middle" fill="#FB8C00" font-size="9" font-weight="600">88°C</text>

  <!-- Isotherm contour lines (50°C, 70°C) -->
  <path d="M 292 286 Q 350 270 408 228 Q 466 210 524 228 Q 560 240 580 260"
        fill="none" stroke="#00C4E8" stroke-width="1" stroke-dasharray="4,3" opacity="0.6"/>
  <text x="548" y="245" fill="#00C4E8" font-size="8" opacity="0.8">50°C</text>

  <path d="M 350 344 Q 380 290 350 228 Q 330 200 350 170"
        fill="none" stroke="#FB8C00" stroke-width="1" stroke-dasharray="4,3" opacity="0.6"/>
  <text x="303" y="228" fill="#FB8C00" font-size="8" opacity="0.8">70°C</text>

  <!-- Routing paths — analog signals curving AROUND the hot zone -->
  <!-- Path 1: Differential pair positive leg — routes below hot zone -->
  <path d="M 89 431 L 175 431 L 200 400 L 250 370 L 280 340 L 280 310 L 260 290 L 240 270 L 220 250"
        fill="none" stroke="#00C4E8" stroke-width="2" stroke-linecap="round"/>
  <!-- Path 2: Differential pair negative leg — mirrored below hot zone -->
  <path d="M 89 373 L 175 373 L 200 350 L 250 330 L 280 310 L 300 290 L 290 270 L 270 250 L 250 230"
        fill="none" stroke="#00E4A8" stroke-width="2" stroke-linecap="round"/>

  <!-- Arrow showing paths diverting around hot zone -->
  <path d="M 330 240 L 350 220" fill="none" stroke="#FF6B6B" stroke-width="1.5" stroke-dasharray="3,2"/>
  <polygon points="350,220 343,228 357,228" fill="#FF6B6B"/>
  <text x="300" y="216" fill="#FF6B6B" font-size="8">HOT — avoided</text>

  <!-- Path labels -->
  <text x="92" y="425" fill="#00C4E8" font-size="8">DIFF+</text>
  <text x="92" y="367" fill="#00E4A8" font-size="8">DIFF−</text>

  <!-- Thermal via stack (bottom-right corner) -->
  <g transform="translate(660, 350)">
    <text x="0" y="-10" fill="#B8D0E8" font-size="10" font-weight="600">Thermal Via</text>
    <!-- Via stack layers -->
    <rect x="5" y="0" width="20" height="8" fill="#1E88E5" stroke="#14263E" stroke-width="0.5"/>
    <text x="28" y="8" fill="#3E5E80" font-size="7">Met2</text>
    <rect x="10" y="8" width="10" height="6" fill="#FB8C00" stroke="#14263E" stroke-width="0.5"/>
    <rect x="5" y="14" width="20" height="8" fill="#1E88E5" stroke="#14263E" stroke-width="0.5"/>
    <text x="28" y="22" fill="#3E5E80" font-size="7">Met1</text>
    <rect x="10" y="22" width="10" height="6" fill="#FB8C00" stroke="#14263E" stroke-width="0.5"/>
    <rect x="5" y="28" width="20" height="8" fill="#43A047" stroke="#14263E" stroke-width="0.5"/>
    <text x="28" y="36" fill="#3E5E80" font-size="7">LI / Diff</text>
    <rect x="10" y="36" width="10" height="10" fill="#555" stroke="#14263E" stroke-width="0.5"/>
    <text x="28" y="48" fill="#3E5E80" font-size="7">Substrate</text>
    <text x="15" y="56" text-anchor="middle" fill="#3E5E80" font-size="7">↓ Package</text>
  </g>

  <!-- Legend: temperature scale gradient -->
  <defs>
    <linearGradient id="tempGrad" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0%" stop-color="#EF5350"/>
      <stop offset="30%" stop-color="#FB8C00"/>
      <stop offset="60%" stop-color="#1E88E5"/>
      <stop offset="100%" stop-color="#060C18"/>
    </linearGradient>
  </defs>
  <rect x="670" y="60" width="18" height="200" fill="url(#tempGrad)" stroke="#14263E" stroke-width="1"/>
  <text x="694" y="68" fill="#EF5350" font-size="9">100°C</text>
  <text x="694" y="118" fill="#FB8C00" font-size="9">70°C</text>
  <text x="694" y="178" fill="#1E88E5" font-size="9">40°C</text>
  <text x="694" y="263" fill="#3E5E80" font-size="9">25°C</text>
  <text x="679" y="48" text-anchor="middle" fill="#B8D0E8" font-size="10" font-weight="600">Temp</text>

  <!-- Legend: routing lines -->
  <line x1="660" y2="300" x2="700" y2="300" stroke="#00C4E8" stroke-width="2"/>
  <text x="706" y="304" fill="#B8D0E8" font-size="9">Analog route</text>
  <line x1="660" y2="318" x2="700" y2="318" stroke="#EF5350" stroke-width="1.5" stroke-dasharray="4,3"/>
  <text x="706" y="322" fill="#B8D0E8" font-size="9">Hot avoidance</text>
  <line x1="660" y2="336" x2="700" y2="336" stroke="#00C4E8" stroke-width="1" stroke-dasharray="4,3" opacity="0.6"/>
  <text x="706" y="340" fill="#B8D0E8" font-size="9">Isotherm</text>

  <!-- Source file label -->
  <text x="450" y="590" text-anchor="middle" fill="#3E5E80" font-size="9">src/router/thermal.zig — ThermalMap, addHotspot (Gaussian), query O(1)</text>
</svg>
```

---

## Thermal Resistance of Wire Segments

Although the current `thermal.zig` does not implement wire-as-thermal-resistor calculations directly, the design intent (described in PHASE7_SPEC.md) is that wire segments conducted by the thermal cost function behave as thermal resistors. The thermal cost between two adjacent A* nodes `a` and `b` is:

```
thermal_cost(a, b) = |T(a) - T(b)| × weight
```

where `T(x)` is the temperature returned by `ThermalMap.query` at the world coordinate of node `x`, and `weight` is a tunable scalar (default `1.0`). A wire segment spanning a large temperature gradient accumulates more thermal cost, discouraging the router from crossing isotherms.

The physical analog: in real silicon, a metal wire does conduct heat, and a wire lying along an isotherm carries less heat flux (and thus creates less thermal perturbation) than a wire cutting across isotherms. The router's thermal cost correctly models the desirable routing objective.

---

## Summary of All Types and Functions

| Symbol | Kind | Location | Summary |
|--------|------|----------|---------|
| `Rect` | struct | thermal.zig:4 | Die bounding box with `width()`, `height()` |
| `ThermalMap` | struct | thermal.zig:10 | 2D float grid of temperatures |
| `ThermalMap.init` | fn | thermal.zig:22 | Allocate grid, fill with ambient |
| `ThermalMap.deinit` | fn | thermal.zig:34 | Free `temps` slice |
| `ThermalMap.query` | fn | thermal.zig:38 | O(1) temperature lookup at (x,y) |
| `ThermalMap.addHotspot` | fn | thermal.zig:45 | Gaussian heat injection at (x,y,radius) |
