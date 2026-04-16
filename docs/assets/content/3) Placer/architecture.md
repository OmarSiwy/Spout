# Analog Placer Architecture

The Spout analog placer is a **Simulated Annealing (SA)** engine purpose-built for analog integrated circuit layout. Unlike digital placers that prioritize throughput for thousands of standard cells, the Spout placer targets circuits of 10–500 devices and applies analog-specific cost terms that enforce electrical matching properties at the physical level.

---

## Source File Map

```
src/placer/
├── cost.zig     — 16-term weighted cost function, all pure stateless functions
├── rudy.zig     — RUDY congestion grid (Spindler & Johannes, DATE 2007)
├── sa.zig       — SA engine: moves, schedule, reheating, hierarchical placement
└── tests.zig    — Integration tests for cost, SA, and RUDY

src/core/
├── device_arrays.zig  — SoA device representation (types, params, positions, dims, orientations, is_dummy)
├── types.zig          — DeviceIdx, NetIdx, PinIdx, ConstraintType, Orientation enums
├── adjacency.zig      — Net–pin adjacency (CSR)
└── layout_if.zig      — PdkConfig: geometry constants loaded from JSON

src/lib.zig            — C-ABI surface; re-exports sa, cost, rudy under placer_types
```

---

## Placement Algorithm: Simulated Annealing

The algorithm is Metropolis–Hastings Simulated Annealing. This technique was chosen because:

1. Analog circuits are small (10–500 devices), so exhaustive evaluation at each temperature level is feasible.
2. Analog constraints (matching, symmetry, common-centroid) create a landscape with many local minima. SA's thermal escape mechanism navigates these barriers.
3. The multi-objective cost function combines incommensurable quantities (wire length in µm, overlap area in µm², binary orientation penalty). SA handles weighted multi-objective problems naturally.

There is no force-directed phase, no initial floorplan step, and no legalization pass in the sense used by digital tools. The SA engine operates directly on floating-point (x, y) coordinates in microns.

---

## Device Representation

Devices are stored in a **Structure-of-Arrays (SoA)** layout in `src/core/device_arrays.zig`:

```zig
pub const DeviceArrays = struct {
    types:         []DeviceType,    // nmos, pmos, res_poly, cap_mim, ...
    params:        []DeviceParams,  // w, l, fingers, mult, value
    positions:     [][2]f32,        // (x, y) centre in microns — THE HOT ARRAY
    dimensions:    [][2]f32,        // (width, height) bounding box in microns
    embeddings:    [][64]f32,       // 64-dim ML embedding (predicted parasitics)
    predicted_cap: []f32,           // ML-predicted capacitance
    orientations:  []Orientation,   // N/S/FN/FS/E/W/FE/FW (DEF standard 8)
    is_dummy:      []bool,          // true → excluded from HPWL and matching cost
    len:           u32,
};
```

All arrays are indexed by the same integer device index. This is the DOD "parallel arrays" pattern: `positions[i]`, `types[i]`, `orientations[i]` all describe device `i`.

### Coordinate System

- **Origin**: lower-left corner of the placement canvas at (0, 0).
- **Units**: floating-point microns (f32). The PDK JSON uses `db_unit = 0.001` µm for GDS export but the placer operates in µm throughout.
- **Device position**: the *centre* of the device bounding box `(x, y)`.
- **Bounding box**: defined by `positions[i]` as centre and `dimensions[i]` as `(width, height)`. The left edge is at `x - width/2`, the right edge at `x + width/2`.
- **Pin positions**: derived as `device_position + transform(pin_offset, orientation)`. Pin offsets are stored in `PinInfo.offset_x/y` relative to the device centre in orientation N (north). When a device is rotated, the offset is transformed by the 8-orientation transform matrix.

### Device Bounding Box Computation

The function `computeDeviceDimensions` in `src/lib.zig` computes conservative bounding boxes from PDK geometry constants:

| Device Class | Bounding Box Formula |
|---|---|
| NMOS | X: `gate_pad_w + poly_ext + ring_ext + w_um + impl_enc + poly_ext + ring_ext`; Y: includes body tap, SD extension, implant enclosure, guard ring |
| PMOS | Same as NMOS but uses `nwell_enc` (0.200 µm) instead of `impl_enc` (0.130 µm) for larger NWELL enclosure |
| res_poly / res_diff / res_well / res_metal | `(p.w * p2um, p.l * p2um)` or default `(2.0, 8.0)` µm |
| cap_mim | `(p.w * p2um, p.l * p2um)` or estimated from density (MIM: 2 fF/µm², others: 1 fF/µm²) |
| cap_mom, cap_pip | Same density estimation |
| cap_gate | Sized like MOSFET `(w × l)` |
| res, cap, ind, subckt, diode, bjt_*, jfet_* | Default `(1.0, 1.0)` µm |

Key PDK constants (sky130, converted to µm from `db_unit = 0.001`):
- `sd_ext = 0.260` µm (source/drain extension beyond gate)
- `poly_ext = 0.150` µm (poly extension beyond active)
- `impl_enc = 0.130` µm (implant enclosure for NMOS)
- `nwell_enc = 0.200` µm (NWELL enclosure for PMOS)
- `gate_pad_w = 0.400` µm (gate contact pad width)
- `tap_gap = 0.270` µm (gap between device active and body tap)
- `tap_diff = 0.340` µm (body tap diffusion height)
- `ring_ext = guard_ring_spacing + guard_ring_width` (guard ring contribution to bounding box)

---

## Constraint Types and Encoding

Constraints are stored in a flat `[]Constraint` array where each element is:

```zig
pub const Constraint = struct {
    kind:   ConstraintType,   // enum(u8): 0–7
    dev_a:  u32,              // device index for first device
    dev_b:  u32,              // device index for second device
    axis_x: f32 = 0.0,        // x-coordinate of vertical symmetry axis
    axis_y: f32 = 0.0,        // y-coordinate of horizontal symmetry axis
    param:  f32 = 0.0,        // kind-dependent: max_dist or min_dist threshold
};
```

The `ConstraintType` enum values as of the current implementation:

| Value | Name | `axis_x` | `axis_y` | `param` | Status |
|---|---|---|---|---|---|
| 0 | `symmetry` | vertical axis x-coord | — | — | Active |
| 1 | `matching` | — | — | — | Active |
| 2 | `proximity` | — | — | max_distance | Active |
| 3 | `isolation` | — | — | min_distance | Active |
| 4 | `symmetry_y` | — | horizontal axis y-coord | — | Active |
| 5 | `orientation_match` | — | — | — | Planned (Phase 2) |
| 6 | `common_centroid` | — | — | group index | Planned (Phase 3) |
| 7 | `interdigitation` | — | — | group index | Planned (Phase 7) |

Group-based constraints (common_centroid, interdigitation) use a sidecar `[]CentroidGroup` array:

```zig
pub const CentroidGroup = struct {
    group_a: []const u32,  // device indices in group A
    group_b: []const u32,  // device indices in group B
};
```

---

## Placement Flow

```
┌─────────────────────────────────────────────────────────┐
│  Input                                                  │
│  • device_positions [][2]f32  (mutable — IN/OUT)        │
│  • device_dimensions []const [2]f32                     │
│  • pin_info []const PinInfo  (device + offset per pin)  │
│  • adj NetAdjacency  (CSR net→pin mapping)              │
│  • constraints []const Constraint                       │
│  • layout_width, layout_height f32                      │
│  • config SaConfig  (weights + schedule params)         │
│  • extended SaExtendedInput  (centroid groups, heat     │
│    sources, interdigitation groups, well regions)       │
└──────────────────────────┬──────────────────────────────┘
                           │
              ┌────────────▼────────────┐
              │  Greedy Initial Place   │
              │  Devices placed in a    │
              │  row with 1 µm gaps.   │
              │  Centred in canvas.     │
              └────────────┬────────────┘
                           │
              ┌────────────▼────────────┐
              │  Pin Position Sync      │
              │  recomputeAllPinPos()   │
              │  transforms offsets by  │
              │  device orientation     │
              └────────────┬────────────┘
                           │
              ┌────────────▼────────────┐
              │  RUDY Grid Init         │
              │  tile_size = 10 µm      │
              │  metal_pitch = 0.5 µm   │
              │  capacity = 2×tile/pitch│
              └────────────┬────────────┘
                           │
              ┌────────────▼────────────┐
              │  Cost Function Init     │
              │  computeFull():         │
              │  16 terms evaluated     │
              └────────────┬────────────┘
                           │
         ┌─────────────────▼─────────────────┐
         │  SA Main Loop (κ·N schedule)       │
         │                                    │
         │  while T > T_min:                  │
         │    alpha = computeAlpha(T, T₀)    │
         │    moves = κ × N_devices          │
         │    for i in 0..moves:             │
         │      runOneMove()  → accept/reject │
         │    if acceptance_rate < 2%:        │
         │      T ×= 3.0  (reheat, max 5×)   │
         │    T ×= alpha                      │
         └─────────────────┬─────────────────┘
                           │
              ┌────────────▼────────────┐
              │  Final Consistency Pass │
              │  recomputeAllPinPos()   │
              │  rudy_grid.computeFull()│
              │  cost_fn.computeFull()  │
              └────────────┬────────────┘
                           │
              ┌────────────▼────────────┐
              │  Post-SA Steps          │
              │  • dummy_count estimate │
              │  • guard ring validation│
              │    (if well_regions set)│
              └────────────┬────────────┘
                           │
              ┌────────────▼────────────┐
              │  Output: SaResult       │
              │  final_cost f32         │
              │  iterations_run u32     │
              │  accepted_moves u32     │
              │  reheat_count u32       │
              │  temperature_levels u32 │
              │  dummy_count u32        │
              │  guard_ring_results []  │
              └─────────────────────────┘
```

---

## Router Interface

The placer outputs device positions in `device_positions [][2]f32` (modified in-place). The router receives:

1. **Final device positions** — each device's (x, y) centre in µm.
2. **Device dimensions** — (width, height) bounding boxes for DRC spacing checks.
3. **Device orientations** — 8-DEF enum; the router must respect pin positions after orientation transform.
4. **Pin positions** — recomputed after SA convergence; each pin's absolute (x, y) in µm.
5. **Net adjacency** (CSR) — the same `NetAdjacency` structure the placer used.

The router (`src/router/`) reads device bounding boxes to block routing tracks within device footprints and uses pin positions as routing endpoints.

---

## Grid Snapping

The placer operates in **continuous floating-point space** during SA. There is no grid snap during optimization. Grid snapping occurs in the GDS exporter (`src/export/gdsii.zig`) when converting µm positions to integer GDS database units at `db_unit = 0.001` µm.

The SA does enforce **hard template bounds** when `config.use_template_bounds = true`:

```zig
template_x_min: f32 = 0.0
template_y_min: f32 = 0.0
template_x_max: f32 = 1.0e9
template_y_max: f32 = 1.0e9
```

A translate move that would place any corner of the device bounding box outside these bounds is immediately rejected (hard constraint, not a cost penalty).

---

## Placement Canvas and Architecture Diagram

```svg
<svg viewBox="0 0 900 650" xmlns="http://www.w3.org/2000/svg" font-family="'Inter', 'Segoe UI', sans-serif">
  <title>Spout Analog Placer — Architecture Overview</title>
  <rect width="900" height="650" fill="#060C18"/>

  <!-- Grid lines -->
  <defs>
    <pattern id="grid" width="50" height="50" patternUnits="userSpaceOnUse">
      <path d="M 50 0 L 0 0 0 50" fill="none" stroke="#0D1E35" stroke-width="0.5"/>
    </pattern>
  </defs>
  <rect x="60" y="40" width="500" height="400" fill="url(#grid)" rx="4"/>
  <rect x="60" y="40" width="500" height="400" fill="none" stroke="#14263E" stroke-width="1.5" rx="4"/>

  <!-- Title -->
  <text x="30" y="26" fill="#00C4E8" font-size="14" font-weight="bold">Spout Analog Placer — Placement Canvas</text>

  <!-- Axis labels -->
  <text x="310" y="460" fill="#3E5E80" font-size="11" text-anchor="middle">X (µm)</text>
  <text x="30" y="240" fill="#3E5E80" font-size="11" text-anchor="middle" transform="rotate(-90,30,240)">Y (µm)</text>
  <text x="62" y="455" fill="#3E5E80" font-size="10">0</text>
  <text x="555" y="455" fill="#3E5E80" font-size="10">500</text>
  <text x="62" y="48" fill="#3E5E80" font-size="10">400</text>

  <!-- Coordinate arrows -->
  <line x1="60" y1="440" x2="570" y2="440" stroke="#14263E" stroke-width="1"/>
  <polygon points="570,437 578,440 570,443" fill="#14263E"/>
  <line x1="60" y1="440" x2="60" y2="35" stroke="#14263E" stroke-width="1"/>
  <polygon points="57,35 60,27 63,35" fill="#14263E"/>

  <!-- Guard ring rectangle (matched pair) -->
  <rect x="120" y="160" width="220" height="160" fill="none" stroke="#AB47BC" stroke-width="2" stroke-dasharray="6,3" rx="6"/>
  <text x="230" y="155" fill="#AB47BC" font-size="10" text-anchor="middle">Guard Ring</text>

  <!-- Symmetry axis (vertical dashed line) -->
  <line x1="230" y1="50" x2="230" y2="430" stroke="#00C4E8" stroke-width="1.5" stroke-dasharray="8,4"/>
  <text x="233" y="62" fill="#00C4E8" font-size="10">Sym Axis x=170µm</text>

  <!-- NMOS device A (inside guard ring) -->
  <rect x="130" y="200" width="80" height="60" fill="#09111F" stroke="#1E88E5" stroke-width="1.5" rx="6"/>
  <text x="170" y="227" fill="#B8D0E8" font-size="11" text-anchor="middle" font-weight="bold">NMOS</text>
  <text x="170" y="241" fill="#3E5E80" font-size="9" text-anchor="middle">M1  W=2µm</text>
  <text x="170" y="253" fill="#3E5E80" font-size="9" text-anchor="middle">pos (130,220)</text>
  <!-- Pin dots -->
  <circle cx="145" cy="200" r="3" fill="#00C4E8"/>
  <circle cx="195" cy="200" r="3" fill="#00C4E8"/>
  <circle cx="145" cy="260" r="3" fill="#43A047"/>

  <!-- NMOS device B (mirror, inside guard ring) -->
  <rect x="280" y="200" width="80" height="60" fill="#09111F" stroke="#1E88E5" stroke-width="1.5" rx="6"/>
  <text x="320" y="227" fill="#B8D0E8" font-size="11" text-anchor="middle" font-weight="bold">NMOS</text>
  <text x="320" y="241" fill="#3E5E80" font-size="9" text-anchor="middle">M2  W=2µm</text>
  <text x="320" y="253" fill="#3E5E80" font-size="9" text-anchor="middle">pos (330,220)</text>
  <circle cx="295" cy="200" r="3" fill="#00C4E8"/>
  <circle cx="345" cy="200" r="3" fill="#00C4E8"/>
  <circle cx="345" cy="260" r="3" fill="#43A047"/>

  <!-- Symmetry constraint arrow -->
  <path d="M 170 215 Q 230 185 320 215" fill="none" stroke="#00C4E8" stroke-width="1.5" stroke-dasharray="4,2" marker-end="url(#arrowCyan)"/>
  <text x="230" y="178" fill="#00C4E8" font-size="9" text-anchor="middle">symmetry constraint</text>

  <!-- PMOS device C -->
  <rect x="130" y="90" width="80" height="50" fill="#09111F" stroke="#EF5350" stroke-width="1.5" rx="6"/>
  <text x="170" y="114" fill="#B8D0E8" font-size="11" text-anchor="middle" font-weight="bold">PMOS</text>
  <text x="170" y="127" fill="#3E5E80" font-size="9" text-anchor="middle">M3  W=4µm</text>
  <circle cx="170" cy="140" r="3" fill="#FB8C00"/>

  <!-- Resistor device -->
  <rect x="420" y="100" width="60" height="90" fill="#09111F" stroke="#43A047" stroke-width="1.5" rx="6"/>
  <text x="450" y="135" fill="#B8D0E8" font-size="11" text-anchor="middle" font-weight="bold">RES</text>
  <text x="450" y="149" fill="#3E5E80" font-size="9" text-anchor="middle">R1</text>
  <text x="450" y="161" fill="#3E5E80" font-size="9" text-anchor="middle">10kΩ</text>
  <circle cx="450" cy="100" r="3" fill="#00C4E8"/>
  <circle cx="450" cy="190" r="3" fill="#00C4E8"/>

  <!-- Capacitor device -->
  <rect x="420" y="280" width="70" height="70" fill="#09111F" stroke="#FB8C00" stroke-width="1.5" rx="6"/>
  <text x="455" y="313" fill="#B8D0E8" font-size="11" text-anchor="middle" font-weight="bold">CAP</text>
  <text x="455" y="327" fill="#3E5E80" font-size="9" text-anchor="middle">C1 MIM</text>
  <circle cx="455" cy="280" r="3" fill="#00C4E8"/>
  <circle cx="455" cy="350" r="3" fill="#00C4E8"/>

  <!-- Proximity arrow: PMOS to NMOS -->
  <line x1="170" y1="145" x2="170" y2="197" stroke="#FB8C00" stroke-width="1.5" stroke-dasharray="4,2"/>
  <text x="105" y="175" fill="#FB8C00" font-size="9">proximity</text>

  <!-- Net wire: NMOS A gate to PMOS -->
  <line x1="145" y1="200" x2="145" y2="140" stroke="#00C4E8" stroke-width="0.8" opacity="0.5"/>
  <line x1="145" y1="140" x2="165" y2="140" stroke="#00C4E8" stroke-width="0.8" opacity="0.5"/>

  <!-- Net wire: NMOS A drain to resistor -->
  <line x1="195" y1="200" x2="350" y2="200" stroke="#43A047" stroke-width="0.8" opacity="0.5"/>
  <line x1="350" y1="200" x2="450" y2="190" stroke="#43A047" stroke-width="0.8" opacity="0.5"/>

  <!-- Matching cost annotation -->
  <path d="M 210 260 L 280 260" fill="none" stroke="#AB47BC" stroke-width="1.5" marker-end="url(#arrowPurple)" marker-start="url(#arrowPurple)"/>
  <text x="245" y="278" fill="#AB47BC" font-size="9" text-anchor="middle">matching dist</text>

  <!-- Arrow marker definitions -->
  <defs>
    <marker id="arrowCyan" markerWidth="8" markerHeight="8" refX="6" refY="3" orient="auto">
      <path d="M0,0 L6,3 L0,6 Z" fill="#00C4E8"/>
    </marker>
    <marker id="arrowPurple" markerWidth="8" markerHeight="8" refX="0" refY="3" orient="auto">
      <path d="M6,0 L0,3 L6,6 Z" fill="#AB47BC"/>
    </marker>
    <marker id="arrowOrange" markerWidth="8" markerHeight="8" refX="6" refY="3" orient="auto">
      <path d="M0,0 L6,3 L0,6 Z" fill="#FB8C00"/>
    </marker>
  </defs>

  <!-- Legend panel -->
  <rect x="585" y="40" width="295" height="590" fill="#09111F" stroke="#14263E" stroke-width="1" rx="6"/>
  <text x="732" y="64" fill="#00C4E8" font-size="13" font-weight="bold" text-anchor="middle">Architecture Legend</text>

  <!-- Legend items -->
  <rect x="600" y="80" width="22" height="14" fill="#09111F" stroke="#1E88E5" stroke-width="1.5" rx="2"/>
  <text x="630" y="93" fill="#B8D0E8" font-size="11">NMOS / PMOS device</text>

  <rect x="600" y="105" width="22" height="14" fill="#09111F" stroke="#43A047" stroke-width="1.5" rx="2"/>
  <text x="630" y="118" fill="#B8D0E8" font-size="11">Resistor device</text>

  <rect x="600" y="130" width="22" height="14" fill="#09111F" stroke="#FB8C00" stroke-width="1.5" rx="2"/>
  <text x="630" y="143" fill="#B8D0E8" font-size="11">Capacitor device</text>

  <rect x="600" y="155" width="22" height="14" fill="none" stroke="#AB47BC" stroke-width="2" stroke-dasharray="4,2" rx="2"/>
  <text x="630" y="168" fill="#B8D0E8" font-size="11">Guard ring perimeter</text>

  <line x1="600" y1="188" x2="622" y2="188" stroke="#00C4E8" stroke-width="1.5" stroke-dasharray="6,3"/>
  <text x="630" y="193" fill="#B8D0E8" font-size="11">Symmetry axis</text>

  <line x1="600" y1="213" x2="622" y2="213" stroke="#AB47BC" stroke-width="1.5" stroke-dasharray="4,2"/>
  <text x="630" y="218" fill="#B8D0E8" font-size="11">Matching constraint</text>

  <line x1="600" y1="238" x2="622" y2="238" stroke="#FB8C00" stroke-width="1.5" stroke-dasharray="4,2"/>
  <text x="630" y="243" fill="#B8D0E8" font-size="11">Proximity constraint</text>

  <circle cx="611" cy="263" r="3" fill="#00C4E8"/>
  <text x="630" y="268" fill="#B8D0E8" font-size="11">Gate/drain/source pin</text>

  <circle cx="611" cy="288" r="3" fill="#43A047"/>
  <text x="630" y="293" fill="#B8D0E8" font-size="11">Body / bulk pin</text>

  <!-- SA schedule info box -->
  <rect x="596" y="310" width="276" height="205" fill="#07101A" stroke="#14263E" stroke-width="1" rx="4"/>
  <text x="734" y="330" fill="#00C4E8" font-size="11" font-weight="bold" text-anchor="middle">SA Schedule</text>
  <text x="605" y="350" fill="#B8D0E8" font-size="10">T₀ = 1000.0</text>
  <text x="605" y="366" fill="#B8D0E8" font-size="10">κ = 20 moves/device/level</text>
  <text x="605" y="382" fill="#3E5E80" font-size="10">Phase 1 (T &gt; 0.30·T₀): α = 0.80</text>
  <text x="605" y="398" fill="#3E5E80" font-size="10">Phase 2 (T &gt; 0.05·T₀): α = 0.97</text>
  <text x="605" y="414" fill="#3E5E80" font-size="10">Phase 3 (T ≤ 0.05·T₀): α = 0.80</text>
  <text x="605" y="430" fill="#B8D0E8" font-size="10">Reheat: acceptance &lt; 2% → T×3</text>
  <text x="605" y="446" fill="#B8D0E8" font-size="10">Max reheats: 5</text>
  <text x="605" y="462" fill="#B8D0E8" font-size="10">ρ(T) = ρ_max × min(1, T/0.3·T₀)</text>
  <text x="605" y="478" fill="#3E5E80" font-size="10">Template bounds: hard rejection</text>
  <text x="605" y="494" fill="#3E5E80" font-size="10">Grid snap: GDS export only</text>
  <text x="605" y="510" fill="#3E5E80" font-size="10">Coord units: f32 µm (centres)</text>

  <!-- Cost function box -->
  <rect x="596" y="525" width="276" height="90" fill="#07101A" stroke="#14263E" stroke-width="1" rx="4"/>
  <text x="734" y="545" fill="#00C4E8" font-size="11" font-weight="bold" text-anchor="middle">16-Term Cost Function</text>
  <text x="605" y="562" fill="#3E5E80" font-size="9">HPWL · Area · Symmetry · Matching</text>
  <text x="605" y="576" fill="#3E5E80" font-size="9">Proximity · Isolation · RUDY · Overlap</text>
  <text x="605" y="590" fill="#3E5E80" font-size="9">Thermal · Orientation · LDE · Centroid</text>
  <text x="605" y="604" fill="#3E5E80" font-size="9">Parasitic · Interdigitation · EdgePenalty · WPE</text>
</svg>
```

---

## C-ABI Interface

The placer is exposed through `src/lib.zig` as a flat C-callable shared library (`libspout.so`). The Python bindings in `python/config.py` mirror the `SaConfig extern struct` field-for-field using `ctypes.Structure`. The struct is `extern` (C layout) and new fields are always appended at the end to preserve ABI compatibility with existing callers.

The `SpoutContext` opaque handle bundles:
- `DeviceArrays` — all device data
- `NetArrays` — net names and metadata
- `PinEdgeArrays` — pin-to-net and pin-to-device connectivity
- `ConstraintArrays` — parsed constraint set
- `RouteArrays` — routing results (null until routing completes)
- `PdkConfig` — geometry constants loaded from JSON at init

The flow is: `spout_init_layout(backend, pdk_id)` → `spout_parse_spice(...)` → `spout_run_sa_placement(...)` → `spout_run_router(...)` → `spout_export_gds(...)`.
