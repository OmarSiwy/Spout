# sky130 Device Library — Layout Rules and Parameters

> **Source files:** `src/lib.zig` (`computeDeviceDimensions`), `pdks/sky130.json`, `src/core/device_arrays.zig`, `src/core/types.zig`

---

## 1. Device Type Taxonomy

Spout's `DeviceType` enum (from `src/core/types.zig`) covers all device categories:

| DeviceType | Category | Spout SPICE Match | Notes |
|---|---|---|---|
| `nmos` | Transistor | `M... nfet/nmos/sky130_fd_pr__nfet_01v8` | Standard NMOS |
| `pmos` | Transistor | `M... pfet/pmos/sky130_fd_pr__pfet_01v8` | Standard PMOS |
| `res_poly` | Resistor | Poly resistor | `R_sheet_poly × L/W` |
| `res_diff_n` | Resistor | N-diff resistor | N+ diffusion stripe |
| `res_diff_p` | Resistor | P-diff resistor | P+ diffusion stripe |
| `res_well_n` | Resistor | N-well resistor | Uses nwell sheet resistance |
| `res_well_p` | Resistor | P-well resistor | Substrate stripe |
| `res_metal` | Resistor | Metal resistor | High-R metal meander |
| `cap_mim` | Capacitor | MIM capacitor | Metal-insulator-metal; ~2 fF/µm² |
| `cap_mom` | Capacitor | MOM capacitor | Metal-oxide-metal interdigitated |
| `cap_pip` | Capacitor | PIP capacitor | Poly-insulator-poly |
| `cap_gate` | Capacitor | Gate capacitor | Uses MOSFET gate oxide |
| `res` | Generic | Any resistor | Behavioral / parametric |
| `cap` | Generic | Any capacitor | Behavioral / parametric |
| `ind` | Inductor | Inductor | Spiral inductor |
| `diode` | Diode | D... element | PN junction |
| `bjt_npn` | BJT | NPN transistor | Q... element |
| `bjt_pnp` | BJT | PNP transistor | Q... element |
| `jfet_n` | JFET | N-JFET | J... element |
| `jfet_p` | JFET | P-JFET | J... element |
| `subckt` | Black-box | .subckt instantiation | External cell |

---

## 2. MOSFET Parameters

### 2.1 `DeviceParams` Struct

Each device has a `DeviceParams` struct:

| Field | Type | Units | Description |
|---|---|---|---|
| `w` | f32 | SPICE meters (×1e6 → µm) | Channel width |
| `l` | f32 | SPICE meters (×1e6 → µm) | Channel length |
| `fingers` | u16 | — | Number of gate fingers |
| `mult` | u16 | — | Multiplicity (parallel instances) |
| `value` | f32 | Context-dependent | R (Ω), C (F), or L (H) for passive devices |

**Scale factor:** `pdks/sky130.json` `param_to_um = 1000000.0`. SPICE parameters are in SI (meters), layout is in µm. A MOSFET with `W=1e-6` in SPICE has `w=1e-6 * 1e6 = 1.0 µm` in layout.

### 2.2 Sky130 Standard MOSFET Constraints

| Parameter | Typical Min | Typical Max | Notes |
|---|---|---|---|
| W (per finger) | 0.42 µm | 100 µm | Wider than min_width due to S/D contact rules |
| L | 0.15 µm | 100 µm | sky130 minimum gate length = 0.15 µm |
| Fingers | 1 | ∞ | Multiple gates in parallel |
| Mult | 1 | ∞ | Full device copies |

Sky130 standard 1.8V MOSFET is `sky130_fd_pr__nfet_01v8` / `sky130_fd_pr__pfet_01v8`.

---

## 3. MOSFET Layout Geometry

### 3.1 Bounding Box Computation (`computeDeviceDimensions` in `src/lib.zig`)

The function computes the full physical bounding box for each device, including all surrounding geometry:

```
Physical constants (in µm, from PDK):
  db = 0.001                  // database unit
  sd_ext    = 0.260 µm        // source/drain extension beyond gate edge
  poly_ext  = 0.150 µm        // poly extension beyond active region
  impl_enc  = 0.130 µm        // implant enclosure around active
  nwell_enc = 0.200 µm        // nwell enclosure (PMOS only, larger than impl_enc)
  gate_pad_w = 0.400 µm       // gate contact pad width (left side)
  tap_gap   = 0.270 µm        // gap from active to body tap
  tap_diff  = 0.340 µm        // body tap diffusion height
  ring_ext  = guard_ring_spacing + guard_ring_width
```

**X-dimension (width):**
```
left  = gate_pad_w + poly_ext + ring_ext
right = w_um + right_enc + poly_ext + ring_ext
  where right_enc = nwell_enc (PMOS) or impl_enc (NMOS)
dim_x = left + right
```

**Y-dimension (height):**
```
bottom = sd_ext + tap_gap + tap_diff + body_bot_margin + ring_ext
  where body_bot_margin = nwell_enc (PMOS) or impl_enc (NMOS)
top    = l_um + sd_ext + top_margin + ring_ext
  where top_margin = nwell_enc (PMOS) or impl_enc (NMOS)
dim_y  = bottom + top
```

The guard ring (`ring_ext`) adds margin around the entire device for isolation. This is included in the bounding box used by the SA placer and the router's obstacle map.

### 3.2 NMOS Layout Structure

An NMOS transistor in sky130 consists of:

1. **Active (diff) region** — `w × l` plus source/drain extensions
2. **Poly gate** — crosses the active region perpendicular to current flow
3. **Source/drain contacts (licon)** — arrays on the diffusion on each side of the gate
4. **LI/M1 connections** — route the S/D contacts to circuit nets
5. **Gate contact** — licon on poly at the left side (gate pad)
6. **Body tap (tap layer 65/44)** — below the active region, connects to substrate (VNB/VSS)
7. **N+ implant (nsdm)** — covers the NMOS active and S/D regions
8. **Guard ring** — ring of tap around the device (optional, for isolation)

### 3.3 PMOS Layout Structure

PMOS adds an nwell region that encloses the entire device:

1. **Nwell (GDS 64/20)** — larger rectangle enclosing diff + tap
2. **Active (diff) region** inside the nwell
3. **Poly gate** — same as NMOS
4. **P+ implant (psdm)** — covers PMOS active/S/D
5. **Body tap** — tap inside nwell connects to VPWR/VPB
6. **Guard ring** — optional ring around nwell

**Key PMOS rule:** `nwell_enc = 0.200 µm` — the nwell must extend at least 0.2 µm past the active region on all sides.

```svg
<svg viewBox="0 0 900 440" xmlns="http://www.w3.org/2000/svg" font-family="'Inter','Segoe UI',sans-serif">
  <rect width="900" height="440" fill="#060C18"/>
  <text x="225" y="22" fill="#B8D0E8" font-size="15" font-weight="bold" text-anchor="middle">NMOS Layout View</text>
  <text x="675" y="22" fill="#B8D0E8" font-size="15" font-weight="bold" text-anchor="middle">PMOS Layout View</text>

  <!-- ══ NMOS (left) ══ -->
  <g transform="translate(30, 35)">
    <!-- Body tap (below active) -->
    <rect x="60" y="290" width="200" height="40" rx="3" fill="#43A047" fill-opacity="0.4" stroke="#43A047" stroke-dasharray="4,3"/>
    <text x="160" y="315" fill="#43A047" font-size="10" text-anchor="middle">body tap (VNB/VSS)</text>

    <!-- Source/drain extensions -->
    <rect x="60" y="100" width="200" height="180" rx="3" fill="#43A047" fill-opacity="0.6" stroke="#43A047" stroke-width="1.5"/>
    <text x="160" y="96" fill="#43A047" font-size="10" text-anchor="middle">diff (active) region</text>

    <!-- N+ implant (nsdm) covers active -->
    <rect x="50" y="92" width="220" height="198" rx="4" fill="none" stroke="#90CAF9" stroke-width="1" stroke-dasharray="6,3"/>
    <text x="260" y="108" fill="#90CAF9" font-size="8">nsdm</text>

    <!-- Poly gate (crosses active) -->
    <rect x="130" y="70" width="24" height="240" rx="2" fill="#EF5350" fill-opacity="0.85" stroke="#EF5350" stroke-width="1.5"/>
    <text x="142" y="65" fill="#EF5350" font-size="10" text-anchor="middle">poly</text>

    <!-- Source region label -->
    <text x="95" y="195" fill="#fff" font-size="10" text-anchor="middle">Source</text>
    <!-- Drain region label -->
    <text x="210" y="195" fill="#fff" font-size="10" text-anchor="middle">Drain</text>

    <!-- Contacts (licon) on source side -->
    <rect x="70" y="145" width="14" height="14" rx="1" fill="#FB8C00"/>
    <rect x="90" y="145" width="14" height="14" rx="1" fill="#FB8C00"/>
    <rect x="70" y="165" width="14" height="14" rx="1" fill="#FB8C00"/>
    <rect x="90" y="165" width="14" height="14" rx="1" fill="#FB8C00"/>
    <rect x="70" y="185" width="14" height="14" rx="1" fill="#FB8C00"/>
    <rect x="90" y="185" width="14" height="14" rx="1" fill="#FB8C00"/>

    <!-- Contacts on drain side -->
    <rect x="175" y="145" width="14" height="14" rx="1" fill="#FB8C00"/>
    <rect x="195" y="145" width="14" height="14" rx="1" fill="#FB8C00"/>
    <rect x="175" y="165" width="14" height="14" rx="1" fill="#FB8C00"/>
    <rect x="195" y="165" width="14" height="14" rx="1" fill="#FB8C00"/>
    <rect x="175" y="185" width="14" height="14" rx="1" fill="#FB8C00"/>
    <rect x="195" y="185" width="14" height="14" rx="1" fill="#FB8C00"/>

    <!-- Gate contact -->
    <rect x="134" y="42" width="14" height="14" rx="1" fill="#FB8C00"/>
    <text x="142" y="38" fill="#FB8C00" font-size="8" text-anchor="middle">G contact</text>

    <!-- Body tap contacts -->
    <rect x="90" y="297" width="10" height="10" rx="1" fill="#FB8C00"/>
    <rect x="108" y="297" width="10" height="10" rx="1" fill="#FB8C00"/>
    <rect x="126" y="297" width="10" height="10" rx="1" fill="#FB8C00"/>
    <rect x="144" y="297" width="10" height="10" rx="1" fill="#FB8C00"/>

    <!-- Dimension: W annotation -->
    <line x1="60" y1="340" x2="260" y2="340" stroke="#00C4E8" stroke-width="1.5" marker-end="url(#da)" marker-start="url(#dal)"/>
    <text x="160" y="355" fill="#00C4E8" font-size="10" text-anchor="middle">W = channel width</text>

    <!-- Dimension: L annotation -->
    <line x1="275" y1="100" x2="275" y2="280" stroke="#00C4E8" stroke-width="1.5" marker-end="url(#da)" marker-start="url(#dal)"/>
    <text x="310" y="195" fill="#00C4E8" font-size="10">L = gate length</text>

    <!-- sd_ext arrows -->
    <line x1="60" y1="100" x2="60" y2="78" stroke="#3E5E80" stroke-width="1" marker-end="url(#da)"/>
    <text x="25" y="90" fill="#3E5E80" font-size="8">sd_ext</text>
    <line x1="60" y1="280" x2="60" y2="295" stroke="#3E5E80" stroke-width="1" marker-end="url(#da)"/>
    <text x="5" y="292" fill="#3E5E80" font-size="8">sd_ext</text>
  </g>

  <!-- ══ PMOS (right) ══ -->
  <g transform="translate(480, 35)">
    <!-- nwell (encloses everything) -->
    <rect x="30" y="50" width="280" height="320" rx="5" fill="#FF6B9D" fill-opacity="0.12" stroke="#FF6B9D" stroke-width="2" stroke-dasharray="8,4"/>
    <text x="160" y="45" fill="#FF6B9D" font-size="10" text-anchor="middle">nwell region</text>

    <!-- P+ implant (psdm) -->
    <rect x="48" y="88" width="224" height="202" rx="4" fill="none" stroke="#F48FB1" stroke-width="1" stroke-dasharray="5,3"/>
    <text x="270" y="104" fill="#F48FB1" font-size="8">psdm</text>

    <!-- Active region -->
    <rect x="60" y="100" width="200" height="180" rx="3" fill="#43A047" fill-opacity="0.6" stroke="#43A047" stroke-width="1.5"/>

    <!-- Poly gate -->
    <rect x="130" y="70" width="24" height="240" rx="2" fill="#EF5350" fill-opacity="0.85" stroke="#EF5350" stroke-width="1.5"/>
    <text x="142" y="65" fill="#EF5350" font-size="10" text-anchor="middle">poly</text>

    <!-- Source (left) label -->
    <text x="95" y="195" fill="#fff" font-size="10" text-anchor="middle">Source</text>
    <text x="210" y="195" fill="#fff" font-size="10" text-anchor="middle">Drain</text>

    <!-- Contacts source side -->
    <rect x="70" y="145" width="14" height="14" rx="1" fill="#FB8C00"/>
    <rect x="90" y="145" width="14" height="14" rx="1" fill="#FB8C00"/>
    <rect x="70" y="165" width="14" height="14" rx="1" fill="#FB8C00"/>
    <rect x="90" y="165" width="14" height="14" rx="1" fill="#FB8C00"/>

    <!-- Contacts drain side -->
    <rect x="175" y="145" width="14" height="14" rx="1" fill="#FB8C00"/>
    <rect x="195" y="145" width="14" height="14" rx="1" fill="#FB8C00"/>
    <rect x="175" y="165" width="14" height="14" rx="1" fill="#FB8C00"/>
    <rect x="195" y="165" width="14" height="14" rx="1" fill="#FB8C00"/>

    <!-- Gate contact -->
    <rect x="134" y="42" width="14" height="14" rx="1" fill="#FB8C00"/>

    <!-- Body tap inside nwell (connects to VPB/VPWR) -->
    <rect x="60" y="295" width="200" height="40" rx="3" fill="#FF6B9D" fill-opacity="0.3" stroke="#FF6B9D" stroke-dasharray="4,3"/>
    <text x="160" y="318" fill="#FF6B9D" font-size="10" text-anchor="middle">p-tap → VPB (nwell tap)</text>

    <!-- nwell_enc annotation -->
    <line x1="30" y1="100" x2="58" y2="100" stroke="#00C4E8" stroke-width="1.5" marker-end="url(#da)" marker-start="url(#dal)"/>
    <text x="10" y="95" fill="#00C4E8" font-size="8">enc</text>
    <text x="10" y="106" fill="#00C4E8" font-size="8">0.20µm</text>

    <!-- W/L annotations -->
    <line x1="60" y1="345" x2="260" y2="345" stroke="#00C4E8" stroke-width="1.5" marker-end="url(#da)" marker-start="url(#dal)"/>
    <text x="160" y="360" fill="#00C4E8" font-size="10" text-anchor="middle">W</text>
    <line x1="275" y1="100" x2="275" y2="280" stroke="#00C4E8" stroke-width="1.5" marker-end="url(#da)" marker-start="url(#dal)"/>
    <text x="285" y="195" fill="#00C4E8" font-size="10">L</text>
  </g>

  <defs>
    <marker id="da" markerWidth="6" markerHeight="5" refX="5" refY="2.5" orient="auto">
      <path d="M0,0 L6,2.5 L0,5 Z" fill="#00C4E8"/>
    </marker>
    <marker id="dal" markerWidth="6" markerHeight="5" refX="1" refY="2.5" orient="auto-start-reverse">
      <path d="M0,0 L6,2.5 L0,5 Z" fill="#00C4E8"/>
    </marker>
  </defs>

  <!-- Legend -->
  <g transform="translate(30, 390)">
    <rect x="0" y="0" width="12" height="12" rx="1" fill="#43A047" fill-opacity="0.6" stroke="#43A047"/>
    <text x="18" y="10" fill="#43A047" font-size="10">Active (diff) GDS 65/20</text>
    <rect x="130" y="0" width="12" height="12" rx="1" fill="#EF5350" fill-opacity="0.85" stroke="#EF5350"/>
    <text x="148" y="10" fill="#EF5350" font-size="10">Poly GDS 66/20</text>
    <rect x="260" y="0" width="12" height="12" rx="1" fill="#FB8C00"/>
    <text x="278" y="10" fill="#FB8C00" font-size="10">licon / contacts GDS 66/44</text>
    <rect x="460" y="0" width="12" height="12" rx="1" fill="#FF6B9D" fill-opacity="0.3" stroke="#FF6B9D"/>
    <text x="478" y="10" fill="#FF6B9D" font-size="10">nwell GDS 64/20 (PMOS only)</text>
  </g>
</svg>
```

---

## 4. Resistor Devices

### 4.1 Bounding Box

Resistor bounding box (from `computeDeviceDimensions`):
```
w = p.w * param_to_um   (or 2.0 µm default)
l = p.l * param_to_um   (or 8.0 µm default)
dimensions = [w, l]
```

The 2×8 µm default gives a 4:1 aspect ratio — typical for a moderate-value resistor.

### 4.2 Resistor Types and Approximate Sheet Resistance

| Type | Material | Approximate R_sheet | sky130 SPICE Model |
|---|---|---|---|
| `res_poly` | Silicided poly | ~48 Ω/sq | `sky130_fd_pr__res_generic_po` |
| `res_diff_n` | N+ diffusion | ~120 Ω/sq | `sky130_fd_pr__res_generic_nd` |
| `res_diff_p` | P+ diffusion | ~200 Ω/sq | `sky130_fd_pr__res_generic_pd` |
| `res_well_n` | N-well | ~1700 Ω/sq | `sky130_fd_pr__res_generic_nw` |
| `res_metal` | Metal meander | ~variable | Layer-dependent |

---

## 5. Capacitor Devices

### 5.1 Bounding Box

Capacitor bounding box (from `computeDeviceDimensions`):
```
if p.w > 0 and p.l > 0:
    dimensions = [p.w * param_to_um, p.l * param_to_um]
else:
    // Estimate from capacitance value
    density = 2e-15 F/µm²  (MIM)   or  1e-15 F/µm²  (MOM/PIP)
    area_um2 = p.value / density
    side = sqrt(area_um2)
    dimensions = [side, side]
```

### 5.2 Capacitor Types

| Type | Density | SPICE Model | Notes |
|---|---|---|---|
| `cap_mim` | ~2 fF/µm² | `sky130_fd_pr__cap_mim_m3_1` | Metal-insulator-metal on M3/M4 |
| `cap_mom` | ~1 fF/µm² | Custom / parametric | Multi-layer metal interdigitation |
| `cap_pip` | ~1 fF/µm² | `sky130_fd_pr__cap_poly` | Poly-insulator-poly |
| `cap_gate` | ~5–10 fF/µm² | Gate oxide | Sized like a MOSFET (W × L) |

---

## 6. Device Orientation

Each device has an `Orientation` field from `types.zig`:

| Orientation | Symbol | Description |
|---|---|---|
| `N` | N | Normal (0°) |
| `S` | S | 180° rotation |
| `E` | E | 90° clockwise |
| `W` | W | 90° counter-clockwise |
| `FN` | FN | Flipped horizontal |
| `FS` | FS | Flipped horizontal + 180° |
| `FE` | FE | Flipped horizontal + 90° CW |
| `FW` | FW | Flipped horizontal + 90° CCW |

The GDSII exporter applies these transformations using GDS `STRANS` records.

---

## 7. Dummy Devices

`DeviceArrays.is_dummy[i] == true` marks a device as a dummy (non-functional):
- Dummy devices are placed to fill space and balance density.
- They are included in the layout (symmetry requires real geometry).
- They are excluded from the LVS schematic.
- The SA placer (`src/placer/sa.zig`) can include or exclude dummies from cost computation.

---

## 8. Liberty / PVT Corner Information

The `src/liberty/pdk.zig` module provides PDK-level information for Liberty file generation:

**sky130 PVT corners:**
- Process corners: `tt`, `ss`, `ff`, `sf`, `fs`
- Voltages: 1.60V, 1.80V, 1.95V (3 voltage points)
- Temperatures: -40°C, 25°C, 100°C (3 temperature points)
- Total: 5 × 3 × 3 = **45 PVT corners**

**sky130 power/ground pin classification:**
| Pin Name | Role |
|---|---|
| VPWR, VDD, VDDA, AVDD | VDD (power) |
| VGND, VSS, VSSA, AVSS, GND | VSS (ground) |
| VPB | nwell bias |
| VNB | pwell bias |

**Model library path:** `$PDK_ROOT/sky130A/libs.tech/ngspice/sky130.lib.spice`

---

## 9. References

| File | Purpose |
|---|---|
| `src/lib.zig` (`computeDeviceDimensions`) | Physical bounding box computation for each device type |
| `src/core/device_arrays.zig` | `DeviceArrays` SoA — all per-device properties |
| `src/core/types.zig` | `DeviceType`, `DeviceParams`, `Orientation` definitions |
| `src/liberty/pdk.zig` | PVT corner enumeration, pin classification |
| `pdks/sky130.json` | PDK geometry constants and layer rules |
| `src/export/gdsii.zig` | GDSII writer — device geometry generation |
