# Phase 7: Thermal Router Specification

## Overview

The Thermal Router provides isotherm-aware routing for analog circuits. Heat-generating devices (power transistors, bandgap cores) create thermal gradients that cause matched devices to mismatch if they sit on different isotherms. The Thermal Router penalizes routing paths that cross isotherms, preferring same-isotherm routes for matched nets.

## ThermalMap Struct

A 2D grid of f32 temperatures covering the die, row-major layout.

| Field | Type | Description |
|-------|------|-------------|
| `temps` | `[]f32` | Row-major flat array of temperatures |
| `rows` | `u32` | Number of rows (Y divisions) |
| `cols` | `u32` | Number of columns (X divisions) |
| `cell_size` | `f32` | Grid cell size in micrometers |
| `bbox_x1` | `f32` | Die bounding box min-X |
| `bbox_y1` | `f32` | Die bounding box min-Y |
| `bbox_x2` | `f32` | Die bounding box max-X |
| `bbox_y2` | `f32` | Die bounding box max-Y |
| `ambient` | `f32` | Ambient temperature (Celsius) |

## ThermalMap API

```zig
pub const ThermalMap = struct {
    allocator: std.mem.Allocator,
    temps: []f32,
    rows: u32,
    cols: u32,
    cell_size: f32,
    bbox_x1: f32,
    bbox_y1: f32,
    bbox_x2: f32,
    bbox_y2: f32,
    ambient: f32,

    pub fn init(allocator: std.mem.Allocator, bbox: Rect, cell_size: f32, ambient: f32) !ThermalMap
    pub fn deinit(self: *ThermalMap) void
    pub fn query(self: *const ThermalMap, x: f32, y: f32) f32
    pub fn addHotspot(self: *ThermalMap, x: f32, y: f32, delta_T: f32, radius: f32) !void
    pub fn extractIsotherm(self: *const ThermalMap, temperature: f32, allocator: std.mem.Allocator) ![]Rect
};
```

## Algorithm: query(x, y) -> f32

O(1) grid lookup:

1. Compute cell indices: `col = (x - bbox_x1) / cell_size`, `row = (y - bbox_y1) / cell_size`
2. Clamp to [0, cols-1] x [0, rows-1]
3. Index = row * cols + col
4. Return `temps[index]`

Returns `ambient` for out-of-bounds coordinates.

## Algorithm: addHotspot(x, y, delta_T, radius)

Simple thermal diffusion model — Gaussian falloff:

1. For each cell within `radius` of (x, y):
   - `distance = sqrt(dx*dx + dy*dy)`
   - `influence = delta_T * exp(-distance^2 / (2 * radius^2))`
   - `temps[cell] += influence`

Bounding box of affected cells computed with integer cell coordinate iteration.

## Algorithm: extractIsotherm(temperature)

Returns list of axis-aligned rectangles approximating the isotherm contour at `temperature`:

1. Scan each grid cell edge (horizontal and vertical)
2. For each edge crossing the isotherm temperature, record the crossing point
3. Connect crossing points to form contour segments
4. Return as list of small axis-aligned rects along the isotherm

Note: Full polygon contour extraction is complex; this returns a conservative set of "near-isotherm" rectangles — cells whose temperature is within 0.1 C of the target.

## Thermal Cost for A* Expansion

```zig
pub fn computeThermalCost(
    point_a: Point,
    point_b: Point,
    thermal_map: *const ThermalMap,
    weight: f32,
) f32 {
    const temp_a = thermal_map.query(point_a.x, point_a.y);
    const temp_b = thermal_map.query(point_b.x, point_b.y);
    return @abs(temp_a - temp_b) * weight;
}
```

- `weight` default = 1.0 (tunable)
- Penalizes routing across temperature gradients
- Same isotherm points have zero thermal cost

## Point Helper

```zig
pub const Point = struct {
    x: f32,
    y: f32,
};
```

## Edge Cases

| Case | Handling |
|------|----------|
| Query out-of-bounds | Returns `ambient` |
| Hotspot with radius 0 | Adds delta_T to single cell |
| No hotspots added | All cells = ambient |
| Negative temperature | Not possible (delta_T is positive offset from ambient) |

## Dependencies

- Phase 1 (`DeviceIdx`, `NetIdx`) — hotspot locations from device power data
- Uses `Rect` from `src/router/IMPL_PLAN.md` (defined there as a doc comment)
- Standalone module, no router dependencies

## Exit Criteria

- [ ] `query()` returns correct temperature from hotspot
- [ ] `addHotspot()` correctly diffuses heat with Gaussian falloff
- [ ] `computeThermalCost()` returns 0 for same-isotherm points
- [ ] `computeThermalCost()` > 0 for points on different isotherms
- [ ] Thermal cost penalizes gradient across differential pair
- [ ] All tests pass: `zig build test 2>&1 | head -50`
