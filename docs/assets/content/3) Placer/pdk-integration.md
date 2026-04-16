# PDK Integration

The Spout placer is tightly coupled to the Process Design Kit (PDK) at two levels:

1. **Device footprint computation** — PDK geometry constants determine device bounding boxes that the placer uses for overlap detection and dimension-dependent cost terms.
2. **Liberty characterization** — PDK PVT corners (process/voltage/temperature) drive the timing and power characterization pipeline that feeds device embeddings and predicted capacitances back into the placer.

---

## PDK JSON Structure (`pdks/sky130.json`)

The PDK configuration is a JSON file that is loaded at `spout_init_layout()` time via `pdk.loadFromFile()`. The sky130 JSON defines:

### Metal Layer Stack

```json
{
  "num_metal_layers": 5,
  "db_unit": 0.001,          // 1 GDS database unit = 0.001 µm
  "param_to_um": 1000000.0,  // SPICE parameter (in meters) → µm conversion
  "tile_size": 1.0,          // routing tile size in µm
  ...
}
```

The `param_to_um` factor of 1,000,000 converts SPICE parameters (given in metres, e.g. `W=2e-6`) to microns for the placer.

### DRC Rules Arrays

Each array has 8 elements — one per metal layer (li1, met1, met2, met3, met4, met5, then two unused slots):

| Field | sky130 Values (µm) | Purpose |
|---|---|---|
| `min_spacing` | [0.14, 0.14, 0.14, 0.28, 0.28, 1.6, 0, 0] | Minimum wire-to-wire spacing per layer |
| `min_width` | [0.14, 0.14, 0.14, 0.30, 0.30, 1.6, 0, 0] | Minimum wire width per layer |
| `via_width` | [0.17, 0.17, 0.15, 0.20, 0.20, 0.80, 0, 0] | Via cut size per layer |
| `min_enclosure` | [0.08, 0.03, 0.055, 0.065, 0.065, 0.31, 0, 0] | Metal enclosure around via |
| `metal_pitch` | [0.34, 0.34, 0.46, 0.68, 0.68, 3.4, 0, 0] | Track pitch (min_width + min_spacing) |
| `same_net_spacing` | [0.14, 0.14, 0.14, 0.28, 0.28, 1.6, 0, 0] | Spacing relaxation for same-net wires |
| `min_area` | [0.083, 0.0676, 0.24, 0.24, 4.0, 0, 0, 0] | Minimum metal area (µm²) |

### Li Layer (Local Interconnect)

Sky130 has a local interconnect (li1) between diffusion/gate and met1:

```json
"li_min_spacing": 0.17,
"li_min_width": 0.17,
"li_min_area": 0.0561
```

### Layer ID Map

The `layers` object maps human-readable names to GDS `[layer, datatype]` pairs:

| Name | GDS Layer | Datatype | Description |
|---|---|---|---|
| `nwell` | 64 | 20 | N-well implant |
| `diff` | 65 | 20 | Active/diffusion region |
| `tap` | 65 | 44 | Well/substrate tap (distinct from diff by datatype) |
| `poly` | 66 | 20 | Polysilicon gate |
| `nsdm` | 93 | 44 | N+ source/drain implant |
| `psdm` | 94 | 20 | P+ source/drain implant |
| `npc` | 95 | 20 | Nitride poly cut (gate silicide block) |
| `licon` | 66 | 44 | Local interconnect contact |
| `li` | 67 | 20 | Local interconnect metal |
| `mcon` | 67 | 44 | Li-to-met1 via |
| `metal[0-4]` | 68–72 | 20 | Metal layers met1–met5 |
| `via[0-3]` | 68–71 | 44 | Via cuts between metal layers |

This layer map is used by the GDS exporter and constraint extractor to identify device geometry in imported layouts.

### Auxiliary DRC Rules

The `aux_rules` array defines non-standard layer-specific design rules:

```json
{"gds_layer": 66, "gds_datatype": 44, "min_width": 0.17, "min_spacing": 0.17}
// → licon: contacts must be 0.17×0.17 µm with 0.17 µm spacing
```

### Enclosure Rules

The `enc_rules` array defines which layers must enclose which other layers:

```json
{"outer_layer": 68, "outer_datatype": 20, "inner_layer": 67, "inner_datatype": 44, "enclosure": 0.06}
// → met1 must enclose mcon by 0.06 µm on all sides
```

### Cross-Layer Spacing Rules

The `cross_rules` array defines spacing requirements between objects on different layers:

```json
{"layer_a": 66, "datatype_a": 20, "layer_b": 65, "datatype_b": 20, "min_spacing": 0.075}
// → poly must be 0.075 µm from diff (poly gate overlap is separate rule)
```

### Metal Direction

```json
"metal_direction": ["horizontal", "vertical", "horizontal", "vertical", "horizontal", ...]
```

Used by the router to assign preferred routing directions per layer and by the RUDY grid to estimate congestion capacity.

---

## Device Footprint Computation

The function `computeDeviceDimensions` in `src/lib.zig` converts device SPICE parameters to physical bounding boxes using PDK geometry constants stored in `PdkConfig`:

```zig
const PdkConfig = struct {
    db_unit:             f32,     // 0.001 µm
    param_to_um:         f32,     // 1e6
    guard_ring_spacing:  f32,     // from PDK rules
    guard_ring_width:    f32,     // from PDK rules
    // ... metal layer arrays
};
```

### NMOS/PMOS Bounding Box

```
Key constants (all derived from PDK, in µm):
  sd_ext    = 0.260  (source/drain extension beyond poly gate edge)
  poly_ext  = 0.150  (poly extension beyond active edge)
  impl_enc  = 0.130  (NMOS: N+ implant enclosure)
  nwell_enc = 0.200  (PMOS: N-well enclosure — larger to cover body tap)
  gate_pad  = 0.400  (gate contact pad width to the left of gate)
  tap_gap   = 0.270  (gap between device active and body tap)
  tap_diff  = 0.340  (body tap diffusion height)
  ring_ext  = guard_ring_spacing + guard_ring_width

Width (X-extent):
  left  = gate_pad + poly_ext + ring_ext
  right = W_um × nf + right_enc + poly_ext + ring_ext
        where right_enc = nwell_enc for PMOS, impl_enc for NMOS
        nf = max(1, params.mult)  (number of fingers × multiplier)
  dim_x = left + right

Height (Y-extent):
  bottom = sd_ext + tap_gap + tap_diff + bot_enc + ring_ext
         where bot_enc = nwell_enc for PMOS, impl_enc for NMOS
  top    = L_um + sd_ext + top_enc + ring_ext
         where top_enc = nwell_enc for PMOS, impl_enc for NMOS
  dim_y  = bottom + top
```

The bounding box is **conservative** (slightly larger than drawn geometry) to ensure adequate clearance between neighbouring devices at the placer level, before the full DRC check in Magic or KLayout.

### PMOS vs. NMOS Sizing Difference

PMOS devices are larger than NMOS in sky130 because:
1. The N-well enclosure (0.200 µm) is larger than the N+ implant enclosure (0.130 µm) on all four sides.
2. The N-well must also enclose the P+ body tap, adding the body tap height to the vertical extent.

Practical effect: a PMOS with `W=2µm, L=0.15µm` has a larger bounding box than an equivalent NMOS, which the placer must account for in symmetry and matching constraints (the `min_sep` derivation uses the larger of width and height).

### Resistor Sizing

```zig
.res_poly, .res_diff_n, .res_diff_p, .res_well_n, .res_well_p, .res_metal => {
    const w = if (p.w > 0.0) p.w * p2um else 2.0;
    const l = if (p.l > 0.0) p.l * p2um else 8.0;
    dimensions[i] = .{ w, l };
}
```

Resistors are sized directly from SPICE W and L parameters. Default `2×8 µm` (4:1 aspect ratio) when unspecified.

### Capacitor Sizing

MIM (Metal-Insulator-Metal) caps: density = 2 fF/µm²
Other cap types: density = 1 fF/µm²

When W and L are specified directly:
```
dim = (w * p2um, l * p2um)
```

When only a capacitance value `C` is specified:
```
area_um2 = C / density
side = sqrt(area_um2)  → square capacitor
dim = (side, side)
```

---

## PdkConfig Loading

The `PdkConfig` is loaded from the bundled JSON at `spout_init_layout()`:

```zig
const pdk_config = layout_if.PdkConfig.loadDefault(pdk_id);
// pdk_id: 0=sky130, 1=gf180, 2=ihp130
```

The caller can override with a custom PDK:
```zig
spout_load_pdk_from_file(handle, path_ptr, path_len)
// Returns 0 on success, -4 on file/parse error
```

This allows using modified PDK corners (e.g. scaled process nodes) or adding new PDKs without recompiling the shared library.

---

## Liberty Integration (`src/liberty/pdk.zig`)

The liberty module provides PDK-specific data for characterization (SPICE simulation to extract timing arcs and power):

### PdkCornerSet

```zig
pub const PdkCornerSet = struct {
    pdk:               PdkId,
    model_lib_dir:     []const u8,    // relative path in PDK tree
    model_file:        []const u8,    // SPICE model file name
    corner_names:      []const []const u8,  // e.g. ["ss", "tt", "ff"]
    voltage_domains:   []const VoltageDomain,
    temperatures:      []const f64,   // e.g. [-40, 27, 85, 125]
    power_pin_names:   []const []const u8,
    ground_pin_names:  []const []const u8,
    nwell_pin_names:   []const []const u8,
    pwell_pin_names:   []const []const u8,
    vdd_net:           []const u8,
    vss_net:           []const u8,
};
```

### sky130 Corner Configuration

The sky130 PDK defines (comptime, in `src/liberty/pdk.zig`):

- **Model directory**: `libs.tech/ngspice`
- **Model file**: `sky130.lib.spice`
- **Corners**: `["ss", "tt", "ff"]`
- **Voltage domains**: 1.8 V nominal with ss/tt/ff nom voltages
- **Temperatures**: [-40°C, 27°C, 85°C, 125°C]
- **Power pins**: VPB, VPWR, VDD
- **Ground pins**: VNB, VGND, VSS
- **N-well pins**: VPB
- **P-well pins**: VNB

### Corner Generation

`PdkCornerSet.generateCorners()` produces a full PVT cross-product:

```
For sky130: 3 corners × 3 voltages × 4 temperatures = 36 PVT corners

Corner name format: "{corner}_{temperature}_{voltage}"
  e.g. "ss_n40C_1v62"  (slow-slow, -40°C, 1.62 V)
       "tt_027C_1v80"  (typical-typical, 27°C, 1.80 V)
       "ff_125C_1v98"  (fast-fast, 125°C, 1.98 V)
```

### Port Role Classification

The `classifyPortForPdk()` method determines how to connect each subcircuit pin in a SPICE testbench:

```zig
.vdd     → connect to VDD supply net
.vss     → connect to VSS ground net
.nwell   → connect to VPB (N-well bias = VDD in standard operation)
.pwell   → connect to VNB (P-well bias = VSS in standard operation)
.signal_in  → drive with stimulus
.signal_out → measure response
.signal_inout → bidirectional signal
```

Classification priority: nwell_pin_names → pwell_pin_names → power_pin_names → ground_pin_names → heuristic signal name detection.

Heuristic signal detection: names containing "OUT", "VOUT", or single-character names "Y", "Q" are classified as outputs; all others as inputs.

---

## Layer Rules and Placement Constraints

PDK layer rules constrain device sizing in ways that affect the placer:

### Well Rules (sky130)

| Rule | Value | Impact on Placer |
|---|---|---|
| nwell min width | 0.84 µm (GDS layer 64) | N-well for PMOS must be wider than minimum |
| nwell min spacing | 1.27 µm (GDS layer 64) | Adjacent N-wells must be separated |
| nwell enclosure of p+ tap | ≥ 0.125 µm | Body tap placement within PMOS bounding box |
| poly min width | 0.15 µm | Gate length L minimum |
| poly min spacing | 0.21 µm (to gate) | Finger-to-finger spacing |

The PMOS bounding box uses `nwell_enc = 0.200 µm` as a conservative enclosure that satisfies the nwell-to-tap and nwell-to-diff enclosure rules simultaneously.

### Tap Cell Requirements

Sky130 requires well taps within 10.5 µm of any active device to prevent latch-up. The placer does not currently enforce this as a cost term, but the device bounding box includes space for an integrated body tap in the MOSFET footprint (`tap_gap = 0.270 µm`, `tap_diff = 0.340 µm`). Separate tap cells for substrate contacts are placed by the router post-placement.

### Guard Ring Geometry

When guard rings are requested:
```
ring_ext = guard_ring_spacing + guard_ring_width
```
This extension is added to all four sides of the device bounding box. The typical sky130 guard ring geometry:
- Inner ring: 0.17 µm (licon) width, 0.17 µm spacing to device active
- Outer ring: adds nwell for PMOS guard rings

The placer uses `ring_ext` in bounding box computation so that the overlap cost term prevents guard rings from overlapping with adjacent devices.

---

## sky130 NMOS Cross-Section

```svg
<svg viewBox="0 0 780 560" xmlns="http://www.w3.org/2000/svg" font-family="'Inter', 'Segoe UI', sans-serif">
  <title>sky130 NMOS Device Cross-Section</title>
  <rect width="780" height="560" fill="#060C18"/>

  <text x="30" y="26" fill="#00C4E8" font-size="14" font-weight="bold">sky130 NMOS — Physical Layer Cross-Section</text>

  <!-- P-substrate base -->
  <rect x="60" y="440" width="640" height="60" fill="#3E2060" stroke="#6A3EA0" stroke-width="1" rx="0"/>
  <text x="380" y="478" fill="#C0A0FF" font-size="11" text-anchor="middle">P-Substrate</text>

  <!-- P-well region -->
  <rect x="100" y="400" width="560" height="45" fill="#2A1A50" stroke="#5A3E80" stroke-width="1"/>
  <text x="380" y="428" fill="#9080C0" font-size="10" text-anchor="middle">P-well (optional, sky130 supports p-well in CMOS)</text>

  <!-- Active / Diffusion regions -->
  <!-- Source diffusion -->
  <rect x="130" y="360" width="120" height="45" fill="#1A4A1A" stroke="#43A047" stroke-width="1.5"/>
  <text x="190" y="387" fill="#43A047" font-size="11" text-anchor="middle">N+ Source</text>
  <text x="190" y="400" fill="#3E5E80" font-size="9" text-anchor="middle">(diff layer 65/20)</text>

  <!-- Drain diffusion -->
  <rect x="490" y="360" width="120" height="45" fill="#1A4A1A" stroke="#43A047" stroke-width="1.5"/>
  <text x="550" y="387" fill="#43A047" font-size="11" text-anchor="middle">N+ Drain</text>
  <text x="550" y="400" fill="#3E5E80" font-size="9" text-anchor="middle">(diff layer 65/20)</text>

  <!-- Channel region -->
  <rect x="250" y="380" width="240" height="25" fill="#1A2A1A" stroke="#3E5E3E" stroke-width="1"/>
  <text x="370" y="397" fill="#3E5E3E" font-size="10" text-anchor="middle">Channel (L = 0.15 µm min)</text>

  <!-- Gate oxide (very thin, represented thicker for visibility) -->
  <rect x="250" y="365" width="240" height="15" fill="#404010" stroke="#80802A" stroke-width="1"/>
  <text x="370" y="378" fill="#CCCC40" font-size="9" text-anchor="middle">Gate Oxide (SiO₂, ~2-3 nm)</text>

  <!-- Poly gate -->
  <rect x="250" y="310" width="240" height="55" fill="#3A1A1A" stroke="#EF5350" stroke-width="2"/>
  <text x="370" y="342" fill="#EF5350" font-size="12" text-anchor="middle">Polysilicon Gate</text>
  <text x="370" y="357" fill="#3E5E80" font-size="9" text-anchor="middle">(poly layer 66/20)</text>

  <!-- N+ source/drain implant markers -->
  <rect x="130" y="355" width="120" height="10" fill="#003020" stroke="#00A060" stroke-width="1" stroke-dasharray="3,2"/>
  <rect x="490" y="355" width="120" height="10" fill="#003020" stroke="#00A060" stroke-width="1" stroke-dasharray="3,2"/>
  <text x="140" y="350" fill="#00A060" font-size="8">nsdm (93/44)</text>
  <text x="500" y="350" fill="#00A060" font-size="8">nsdm (93/44)</text>

  <!-- Licon contacts in source -->
  <rect x="155" y="335" width="15" height="28" fill="#806000" stroke="#FFC107" stroke-width="1" rx="2"/>
  <rect x="185" y="335" width="15" height="28" fill="#806000" stroke="#FFC107" stroke-width="1" rx="2"/>
  <rect x="215" y="335" width="15" height="28" fill="#806000" stroke="#FFC107" stroke-width="1" rx="2"/>

  <!-- Licon contacts in drain -->
  <rect x="505" y="335" width="15" height="28" fill="#806000" stroke="#FFC107" stroke-width="1" rx="2"/>
  <rect x="535" y="335" width="15" height="28" fill="#806000" stroke="#FFC107" stroke-width="1" rx="2"/>
  <rect x="565" y="335" width="15" height="28" fill="#806000" stroke="#FFC107" stroke-width="1" rx="2"/>

  <!-- Gate licon (poly contact) -->
  <rect x="355" y="280" width="15" height="32" fill="#806000" stroke="#FFC107" stroke-width="1" rx="2"/>
  <rect x="375" y="280" width="15" height="32" fill="#806000" stroke="#FFC107" stroke-width="1" rx="2"/>

  <!-- Local interconnect (Li) over source and drain -->
  <rect x="130" y="300" width="120" height="38" fill="#1A1A4A" stroke="#5050CC" stroke-width="1.5" rx="2" opacity="0.85"/>
  <text x="190" y="321" fill="#8080FF" font-size="9" text-anchor="middle">Li (67/20)</text>
  <text x="190" y="333" fill="#3E5E80" font-size="8" text-anchor="middle">local interconnect</text>

  <rect x="490" y="300" width="120" height="38" fill="#1A1A4A" stroke="#5050CC" stroke-width="1.5" rx="2" opacity="0.85"/>
  <text x="550" y="321" fill="#8080FF" font-size="9" text-anchor="middle">Li (67/20)</text>

  <!-- Gate Li -->
  <rect x="320" y="248" width="120" height="35" fill="#1A1A4A" stroke="#5050CC" stroke-width="1.5" rx="2" opacity="0.85"/>
  <text x="380" y="268" fill="#8080FF" font-size="9" text-anchor="middle">Gate Li (67/20)</text>

  <!-- Mcon vias (Li to Met1) -->
  <rect x="155" y="262" width="12" height="40" fill="#806000" stroke="#FFCC00" stroke-width="0.8" rx="1"/>
  <rect x="195" y="262" width="12" height="40" fill="#806000" stroke="#FFCC00" stroke-width="0.8" rx="1"/>
  <rect x="235" y="262" width="12" height="40" fill="#806000" stroke="#FFCC00" stroke-width="0.8" rx="1"/>

  <rect x="510" y="262" width="12" height="40" fill="#806000" stroke="#FFCC00" stroke-width="0.8" rx="1"/>
  <rect x="545" y="262" width="12" height="40" fill="#806000" stroke="#FFCC00" stroke-width="0.8" rx="1"/>
  <rect x="578" y="262" width="12" height="40" fill="#806000" stroke="#FFCC00" stroke-width="0.8" rx="1"/>

  <!-- Met1 source bar -->
  <rect x="100" y="230" width="200" height="34" fill="#0A2A4A" stroke="#1E88E5" stroke-width="2" rx="3"/>
  <text x="200" y="252" fill="#1E88E5" font-size="11" text-anchor="middle">Met1 Source (68/20)</text>

  <!-- Met1 drain bar -->
  <rect x="470" y="230" width="200" height="34" fill="#0A2A4A" stroke="#1E88E5" stroke-width="2" rx="3"/>
  <text x="570" y="252" fill="#1E88E5" font-size="11" text-anchor="middle">Met1 Drain (68/20)</text>

  <!-- Met1 gate bar -->
  <rect x="290" y="200" width="200" height="30" fill="#0A2A4A" stroke="#1E88E5" stroke-width="2" rx="3"/>
  <text x="390" y="220" fill="#1E88E5" font-size="11" text-anchor="middle">Met1 Gate (68/20)</text>

  <!-- Gate poly extension label -->
  <line x1="250" y1="308" x2="130" y2="308" stroke="#3E5E80" stroke-width="0.8" stroke-dasharray="2,2"/>
  <line x1="130" y1="295" x2="130" y2="365" stroke="#3E5E80" stroke-width="0.8"/>
  <text x="85" y="334" fill="#3E5E80" font-size="8" text-anchor="middle">poly_ext</text>
  <text x="85" y="344" fill="#3E5E80" font-size="8" text-anchor="middle">0.150 µm</text>

  <!-- SD extension labels -->
  <line x1="250" y1="393" x2="130" y2="393" stroke="#3E5E80" stroke-width="0.8" stroke-dasharray="2,2"/>
  <text x="185" y="420" fill="#3E5E80" font-size="8" text-anchor="middle">sd_ext = 0.260 µm</text>

  <!-- Gate length label -->
  <line x1="250" y1="466" x2="490" y2="466" stroke="#00C4E8" stroke-width="1"/>
  <line x1="250" y1="460" x2="250" y2="472" stroke="#00C4E8" stroke-width="1"/>
  <line x1="490" y1="460" x2="490" y2="472" stroke="#00C4E8" stroke-width="1"/>
  <text x="370" y="484" fill="#00C4E8" font-size="10" text-anchor="middle">L (gate length, min 0.15 µm)</text>

  <!-- Device width label -->
  <line x1="700" y1="360" x2="700" y2="405" stroke="#43A047" stroke-width="1"/>
  <line x1="694" y1="360" x2="706" y2="360" stroke="#43A047" stroke-width="1"/>
  <line x1="694" y1="405" x2="706" y2="405" stroke="#43A047" stroke-width="1"/>
  <text x="720" y="387" fill="#43A047" font-size="10">W</text>

  <!-- Layer color legend -->
  <rect x="60" y="500" width="680" height="50" fill="#09111F" stroke="#14263E" stroke-width="1" rx="4"/>
  <rect x="75" y="515" width="20" height="12" fill="#1A4A1A" stroke="#43A047" stroke-width="1"/>
  <text x="100" y="526" fill="#43A047" font-size="10">diff (65/20)</text>
  <rect x="175" y="515" width="20" height="12" fill="#3A1A1A" stroke="#EF5350" stroke-width="1"/>
  <text x="200" y="526" fill="#EF5350" font-size="10">poly (66/20)</text>
  <rect x="280" y="515" width="20" height="12" fill="#806000" stroke="#FFC107" stroke-width="1"/>
  <text x="305" y="526" fill="#FFC107" font-size="10">licon (66/44)</text>
  <rect x="395" y="515" width="20" height="12" fill="#1A1A4A" stroke="#5050CC" stroke-width="1"/>
  <text x="420" y="526" fill="#8080FF" font-size="10">li (67/20)</text>
  <rect x="490" y="515" width="20" height="12" fill="#806000" stroke="#FFCC00" stroke-width="1"/>
  <text x="515" y="526" fill="#FFCC00" font-size="10">mcon (67/44)</text>
  <rect x="605" y="515" width="20" height="12" fill="#0A2A4A" stroke="#1E88E5" stroke-width="1"/>
  <text x="630" y="526" fill="#1E88E5" font-size="10">met1 (68/20)</text>

  <rect x="75" y="533" width="20" height="12" fill="#3E2060" stroke="#6A3EA0" stroke-width="1"/>
  <text x="100" y="544" fill="#C0A0FF" font-size="10">substrate</text>
  <rect x="175" y="533" width="20" height="12" fill="#2A1A50" stroke="#5A3E80" stroke-width="1"/>
  <text x="200" y="544" fill="#9080C0" font-size="10">p-well</text>
  <rect x="280" y="533" width="20" height="12" fill="#003020" stroke="#00A060" stroke-width="1" stroke-dasharray="2,2"/>
  <text x="305" y="544" fill="#00A060" font-size="10">nsdm (93/44)</text>
  <text x="420" y="544" fill="#3E5E80" font-size="10">gate oxide: ~2-3 nm SiO₂ (not GDS layer)</text>
</svg>
```

---

## Python FFI Configuration (`python/config.py`)

The Python layer mirrors the `SaConfig extern struct` byte-for-byte using `ctypes.Structure`:

```python
class _SaConfigC(ctypes.Structure):
    _fields_ = [
        ("initialTemp",                ctypes.c_float),
        ("coolingRate",                ctypes.c_float),
        ("minTemp",                    ctypes.c_float),
        ("maxIterations",              ctypes.c_uint32),
        ("perturbationRange",          ctypes.c_float),
        ("wHpwl",                      ctypes.c_float),
        ("wArea",                      ctypes.c_float),
        ("wSymmetry",                  ctypes.c_float),
        ("wMatching",                  ctypes.c_float),
        ("wRudy",                      ctypes.c_float),
        ("wOverlap",                   ctypes.c_float),
        # ... additional weight fields
    ]
```

The Python `SpoutConfig` class provides the top-level pipeline configuration:

| Field | Default | Description |
|---|---|---|
| `backend` | `"magic"` | Layout verification backend: `"magic"` or `"klayout"` |
| `pdk` | `"sky130"` | PDK name: `"sky130"`, `"gf180"`, `"ihp130"` |
| `pdk_id` | 0 | Integer PDK ID: 0=sky130, 1=gf180, 2=ihp130 |
| `pdk_root` | `$PDK_ROOT` | Filesystem path to PDK installation |
| `sa_config` | `SaConfig()` | SA hyperparameters |
| `use_moead_placement` | False | Use MOEA/D instead of SA when available |
| `use_detailed_routing` | False | Use detailed routing entrypoint |
| `output_dir` | `"spout_output"` | Directory for outputs |
| `macros` | `[]` | User-defined macro subcircuits |

### PDK Variant Paths

```python
_PDK_VARIANTS = {
    "sky130": "sky130A",
    "gf180":  "gf180mcuD",
    "ihp130": "ihp-sg13g2",
}

# Tech file paths for DRC/LVS signoff:
_TECH_FILES = {
    ("magic",   "sky130"): "libs.tech/magic/sky130A.tech",
    ("klayout", "sky130"): "libs.tech/klayout/sky130A.lyt",
    ...
}
```

The full path to a sky130 Magic tech file is:
```
{pdk_root}/sky130A/libs.tech/magic/sky130A.tech
```

---

## Build System Integration (`build.zig`)

The Zig build produces three artifacts:

| Target | Command | Output | Purpose |
|---|---|---|---|
| Shared library | `zig build` | `python/libspout.so` | ctypes FFI for Python |
| Python extension | `zig build pyext` | `python/spout.so` | Native CPython extension (faster than ctypes) |
| Unit tests | `zig build test` | — | Runs all `test` blocks in src/ |
| End-to-end tests | `zig build e2e` | — | Runs tests/e2e_tests.zig |

The `spout_mod` Zig module (`src/lib.zig`) is the root for both the shared library and all test binaries. All placer, router, and PDK submodules are imported transitively through `lib.zig`.

The Python extension (`src/python_ext.zig`) uses the PyOZ library (a Zig-native Python C extension framework) to expose higher-level APIs directly as Python functions without ctypes marshalling overhead.
