# PDK JSON Reference

The PDK JSON file is the single source of truth for all process-design-kit geometry parameters consumed by Spout. It encodes the physical design rules, layer stack, and routing constraints for one PDK. The authoritative reference implementation is `pdks/sky130.json`.

This document specifies every field. A conforming PDK JSON file for any other process can be written from this specification.

---

## Top-Level Object

The JSON file is a single object. All fields are required unless noted as optional.

---

## Scalar Fields

### `name`
**Type:** string
**Example:** `"sky130"`
**Consumed by:** Router, Liberty, DRC — used for logging and PDK identification. Should match the directory name in the Volare PDK tree.

---

### `num_metal_layers`
**Type:** integer
**Example:** `5`
**Consumed by:** Router — determines the number of usable routing layers. sky130 has 5 metal layers (li1 through met4, though the router indexes from 1). The router allocates routing grids only up to this count.

---

### `db_unit`
**Type:** float
**Example:** `0.001`
**Units:** µm per database unit
**Consumed by:** GDS exporter (`gds_area.zig`), router, layout writer — all coordinate arithmetic. sky130 uses 1 database unit = 1 nm = 0.001 µm. This is also the `gds_db_unit_um` field in `LibertyConfig`.

---

### `param_to_um`
**Type:** float
**Example:** `1000000.0`
**Units:** factor to multiply SPICE parameter values (in meters) to get µm
**Consumed by:** `computeDeviceDimensions` in `lib.zig` — converts SPICE `.subckt` W/L parameters (which are in meters in standard SPICE) to µm for bounding-box calculation. `1e6` because 1 m × 1e6 = 1e6 µm.

---

### `tile_size`
**Type:** float
**Example:** `1.0`
**Units:** µm
**Consumed by:** Router — sets the routing grid cell size. A tile_size of 1.0 µm means each cell in the routing grid is 1 µm × 1 µm. The router places wire segments on this grid.

---

### `li_min_spacing`
**Type:** float
**Example:** `0.17`
**Units:** µm
**Consumed by:** DRC — minimum spacing between local interconnect (LI / li1) shapes on the same net or different nets.

---

### `li_min_width`
**Type:** float
**Example:** `0.17`
**Units:** µm
**Consumed by:** DRC — minimum width of a local interconnect (li1) shape.

---

### `li_min_area`
**Type:** float
**Example:** `0.0561`
**Units:** µm²
**Consumed by:** DRC — minimum enclosed area for an LI shape. Prevents degenerate slivers.

---

## Array Fields (Per-Layer Indexed)

All array fields use a consistent layer index scheme. Index 0 corresponds to the first routing layer (li1 in sky130), index 1 to metal1, ..., index `num_metal_layers - 1` to the topmost metal. Trailing zeros pad the arrays to a fixed length (8 entries in sky130.json).

---

### `min_spacing`
**Type:** array of float
**Example:** `[0.14, 0.14, 0.14, 0.28, 0.28, 1.6, 0.0, 0.0]`
**Units:** µm
**Consumed by:** Router inline DRC, post-route DRC — minimum spacing between edges of shapes on the same layer (different net context, typically same-layer minimum spacing).

| Index | Layer | Value (µm) |
|---|---|---|
| 0 | li1 | 0.14 |
| 1 | met1 | 0.14 |
| 2 | met2 | 0.14 |
| 3 | met3 | 0.28 |
| 4 | met4 | 0.28 |
| 5 | met5 (RDL) | 1.6 |
| 6–7 | (unused) | 0.0 |

---

### `min_width`
**Type:** array of float
**Example:** `[0.14, 0.14, 0.14, 0.30, 0.30, 1.6, 0.0, 0.0]`
**Units:** µm
**Consumed by:** Router, DRC — minimum wire width on each metal layer.

| Index | Layer | Value (µm) |
|---|---|---|
| 0 | li1 | 0.14 |
| 1 | met1 | 0.14 |
| 2 | met2 | 0.14 |
| 3 | met3 | 0.30 |
| 4 | met4 | 0.30 |
| 5 | met5 | 1.6 |

---

### `via_width`
**Type:** array of float
**Example:** `[0.17, 0.17, 0.15, 0.20, 0.20, 0.80, 0.0, 0.0]`
**Units:** µm
**Consumed by:** Router, GDS exporter — size of via cuts between adjacent metal layers. Index i represents the via between layer i and layer i+1.

| Index | Via | Value (µm) |
|---|---|---|
| 0 | licon (li1→met1) | 0.17 |
| 1 | mcon (met1→met2) | 0.17 |
| 2 | via1 (met2→met3) | 0.15 |
| 3 | via2 (met3→met4) | 0.20 |
| 4 | via3 (met4→met5) | 0.20 |
| 5 | via4 (met5→RDL) | 0.80 |

---

### `min_enclosure`
**Type:** array of float
**Example:** `[0.08, 0.03, 0.055, 0.065, 0.065, 0.31, 0.0, 0.0]`
**Units:** µm
**Consumed by:** Router via placement, GDS exporter — minimum enclosure of a via cut by the metal layer above or below it.

| Index | Via | Enclosure (µm) |
|---|---|---|
| 0 | licon | 0.08 |
| 1 | mcon | 0.03 |
| 2 | via1 | 0.055 |
| 3 | via2 | 0.065 |
| 4 | via3 | 0.065 |
| 5 | via4 | 0.31 |

---

### `metal_pitch`
**Type:** array of float
**Example:** `[0.34, 0.34, 0.46, 0.68, 0.68, 3.4, 0.0, 0.0]`
**Units:** µm
**Consumed by:** Router — preferred routing pitch (wire center-to-center spacing). Derived as `min_width + min_spacing` on each layer (but specified explicitly to allow override). The router snaps wire positions to multiples of this pitch.

| Index | Layer | Pitch (µm) |
|---|---|---|
| 0 | li1 | 0.34 |
| 1 | met1 | 0.34 |
| 2 | met2 | 0.46 |
| 3 | met3 | 0.68 |
| 4 | met4 | 0.68 |
| 5 | met5 | 3.4 |

---

### `same_net_spacing`
**Type:** array of float
**Example:** `[0.14, 0.14, 0.14, 0.28, 0.28, 1.6, 0.0, 0.0]`
**Units:** µm
**Consumed by:** DRC — minimum spacing between shapes of the same net on the same layer. In sky130 this is equal to `min_spacing` for all metal layers.

---

### `min_area`
**Type:** array of float
**Example:** `[0.083, 0.0676, 0.24, 0.24, 4.0, 0.0, 0.0, 0.0]`
**Units:** µm²
**Consumed by:** DRC — minimum enclosed area for a single shape on each metal layer. Prevents tiny floating slivers.

| Index | Layer | Min area (µm²) |
|---|---|---|
| 0 | li1 | 0.083 |
| 1 | met1 | 0.0676 |
| 2 | met2 | 0.24 |
| 3 | met3 | 0.24 |
| 4 | met4 | 4.0 |

---

### `layer_map`
**Type:** array of integer (GDS layer numbers)
**Example:** `[67, 68, 69, 70, 71, 0, 0, 0]`
**Consumed by:** GDS exporter, router — maps router layer indices to GDS layer numbers. Layer_map[0] = 67 means the first routing layer (li1) corresponds to GDS layer 67. Used when writing GDSII output to select the correct layer number for each routed wire.

| Router index | GDS layer | sky130 name |
|---|---|---|
| 0 | 67 | li (local interconnect) |
| 1 | 68 | met1 |
| 2 | 69 | met2 |
| 3 | 70 | met3 |
| 4 | 71 | met4 |

---

### `metal_direction`
**Type:** array of string
**Values:** `"horizontal"` or `"vertical"`
**Example:** `["horizontal", "vertical", "horizontal", "vertical", "horizontal", ...]`
**Consumed by:** Router — preferred routing direction for each layer. Alternating H/V is the standard preferred-direction routing constraint used by maze and detailed routers to reduce layer crossings.

| Router index | Layer | Direction |
|---|---|---|
| 0 | li1 | horizontal |
| 1 | met1 | vertical |
| 2 | met2 | horizontal |
| 3 | met3 | vertical |
| 4 | met4 | horizontal |

---

## `layers` Object

Maps semantic layer names to GDS `[layer_number, datatype]` pairs (or arrays of pairs for multi-layer groups).

```json
"layers": {
  "nwell":     [64, 20],
  "diff":      [65, 20],
  "tap":       [65, 44],
  "poly":      [66, 20],
  "nsdm":      [93, 44],
  "psdm":      [94, 20],
  "npc":       [95, 20],
  "licon":     [66, 44],
  "li":        [67, 20],
  "mcon":      [67, 44],
  "metal":     [[68, 20], [69, 20], [70, 20], [71, 20], [72, 20]],
  "via":       [[68, 44], [69, 44], [70, 44], [71, 44]],
  "li_pin":    [67, 5],
  "metal_pin": [[68, 5], [69, 5], [70, 5], [71, 5], [72, 5]]
}
```

**Consumed by:** GDS exporter (writing shapes to correct layers), DRC (identifying layers by semantic name), Liberty/PEX (identifying active device regions).

| Key | Type | GDS layer/datatype | Semantic |
|---|---|---|---|
| `nwell` | `[int, int]` | 64/20 | N-well region (PMOS body) |
| `diff` | `[int, int]` | 65/20 | Active diffusion (MOSFET source/drain) |
| `tap` | `[int, int]` | 65/44 | Tap diffusion (body contact) |
| `poly` | `[int, int]` | 66/20 | Polysilicon gate |
| `nsdm` | `[int, int]` | 93/44 | N-source/drain implant mask |
| `psdm` | `[int, int]` | 94/20 | P-source/drain implant mask |
| `npc` | `[int, int]` | 95/20 | Not-poly-cut mask (used for poly resistors) |
| `licon` | `[int, int]` | 66/44 | Local interconnect contact (gate/diffusion to li1) |
| `li` | `[int, int]` | 67/20 | Local interconnect metal (li1) |
| `mcon` | `[int, int]` | 67/44 | Metal contact (li1 to met1) |
| `metal` | `[[int,int],...]` | 68–72/20 | Metal layers met1 through met5 |
| `via` | `[[int,int],...]` | 68–71/44 | Via cuts between metal layers |
| `li_pin` | `[int, int]` | 67/5 | Pin label layer on li1 |
| `metal_pin` | `[[int,int],...]` | 68–72/5 | Pin label layers on met1–met5 |

The `metal` array has 5 entries (met1–met5); `via` has 4 entries (via1–via4); `metal_pin` has 5 entries.

---

## `aux_rules` Array

Additional single-layer DRC rules beyond what is captured in the per-layer arrays. Each element is an object:

```json
{
  "gds_layer": 66,
  "gds_datatype": 44,
  "min_width": 0.17,
  "min_spacing": 0.17,
  "min_area": 0.0
}
```

**Consumed by:** DRC — applied to shapes matching the `(gds_layer, gds_datatype)` pair.

| Field | Type | Meaning |
|---|---|---|
| `gds_layer` | integer | GDS layer number |
| `gds_datatype` | integer | GDS datatype number |
| `min_width` | float (µm) | Minimum shape width on this layer/datatype |
| `min_spacing` | float (µm) | Minimum spacing between shapes on this layer/datatype |
| `min_area` | float (µm²) | Minimum enclosed area (0 = no area rule) |

**All 7 aux_rules entries in sky130.json:**

| gds_layer | gds_datatype | min_width | min_spacing | min_area | Interpretation |
|---|---|---|---|---|---|
| 66 | 44 | 0.17 | 0.17 | 0 | licon contacts |
| 67 | 44 | 0.17 | 0.19 | 0 | mcon contacts |
| 68 | 44 | 0.15 | 0.17 | 0 | via1 cuts |
| 65 | 20 | 0.26 | 0.27 | 0 | diff layer wide rules |
| 65 | 44 | 0.17 | 0.27 | 0 | tap contacts |
| 66 | 20 | 0.15 | 0.21 | 0 | poly gate width |
| 64 | 20 | 0.84 | 1.27 | 0 | nwell large spacing |

---

## `enc_rules` Array

Enclosure rules: the outer layer must enclose the inner layer by at least the specified amount. Each element:

```json
{
  "outer_layer": 68,
  "outer_datatype": 20,
  "inner_layer": 67,
  "inner_datatype": 44,
  "enclosure": 0.06
}
```

**Consumed by:** DRC — checks that every shape on `(inner_layer, inner_datatype)` is enclosed by at least `enclosure` µm by an overlapping shape on `(outer_layer, outer_datatype)`.

| Field | Type | Meaning |
|---|---|---|
| `outer_layer` | integer | GDS layer of enclosing shape |
| `outer_datatype` | integer | GDS datatype of enclosing shape |
| `inner_layer` | integer | GDS layer of enclosed shape (e.g. via cut) |
| `inner_datatype` | integer | GDS datatype of enclosed shape |
| `enclosure` | float (µm) | Minimum enclosure distance on all sides |

**All 11 enc_rules entries in sky130.json:**

| Outer | Inner | Enclosure (µm) | Interpretation |
|---|---|---|---|
| 68/20 (met1) | 67/44 (mcon) | 0.06 | met1 encloses mcon |
| 65/44 (tap) | 66/44 (licon) | 0.12 | tap encloses licon |
| 68/20 (met1) | 68/44 (via1) | 0.03 | met1 encloses via1 |
| 69/20 (met2) | 68/44 (via1) | 0.03 | met2 encloses via1 |
| 67/20 (li) | 67/44 (mcon) | 0.0 | li encloses mcon (no extra margin) |
| 69/20 (met2) | 69/44 (via2) | 0.055 | met2 encloses via2 |
| 67/20 (li) | 66/44 (licon) | 0.08 | li encloses licon |
| 64/20 (nwell) | 65/44 (tap) | 0.18 | nwell encloses tap |
| 65/20 (diff) | 66/44 (licon) | 0.04 | diff encloses licon |
| 68/20 (met1) | 66/44 (licon) | 0.06 | met1 encloses licon |
| 65/20 (diff) | 66/44 (licon) | 0.12 | diff encloses licon (duplicate with different enc) |

---

## `cross_rules` Array

Minimum spacing between shapes on two different layers (cross-layer spacing rules). Each element:

```json
{
  "layer_a": 66,
  "datatype_a": 20,
  "layer_b": 65,
  "datatype_b": 20,
  "min_spacing": 0.075
}
```

**Consumed by:** DRC — checks that shapes on `(layer_a, datatype_a)` maintain at least `min_spacing` from shapes on `(layer_b, datatype_b)`.

| Field | Type | Meaning |
|---|---|---|
| `layer_a` | integer | GDS layer of first shape |
| `datatype_a` | integer | GDS datatype of first shape |
| `layer_b` | integer | GDS layer of second shape |
| `datatype_b` | integer | GDS datatype of second shape |
| `min_spacing` | float (µm) | Minimum clearance between the two shape sets |

**All 7 cross_rules entries in sky130.json:**

| Layer A | Layer B | Spacing (µm) | Interpretation |
|---|---|---|---|
| 66/20 (poly) | 65/20 (diff) | 0.075 | poly to diff spacing |
| 66/20 (poly) | 65/44 (tap) | 0.055 | poly to tap spacing |
| 66/44 (licon) | 65/20 (diff) | 0.19 | licon to diff spacing |
| 66/44 (licon) | 65/44 (tap) | 0.055 | licon to tap spacing |
| 66/44 (licon) | 66/20 (poly) | 0.055 | licon to poly spacing |
| 65/44 (tap) | 64/20 (nwell) | 0.13 | tap to nwell edge spacing |
| 65/20 (diff) | 64/20 (nwell) | 0.34 | diff to nwell edge spacing |

---

## Complete Field Summary

| Field | Type | Units | Consumed by |
|---|---|---|---|
| `name` | string | — | All subsystems |
| `num_metal_layers` | int | — | Router |
| `db_unit` | float | µm/db_unit | GDS reader/writer, Liberty |
| `param_to_um` | float | µm/m | Device dimension calc |
| `tile_size` | float | µm | Router grid |
| `min_spacing` | float[8] | µm | Router DRC, post-route DRC |
| `min_width` | float[8] | µm | Router, DRC |
| `via_width` | float[8] | µm | Router, GDS exporter |
| `min_enclosure` | float[8] | µm | Router via placement |
| `metal_pitch` | float[8] | µm | Router grid alignment |
| `same_net_spacing` | float[8] | µm | DRC |
| `li_min_spacing` | float | µm | DRC (li1 specific) |
| `li_min_width` | float | µm | DRC (li1 specific) |
| `li_min_area` | float | µm² | DRC (li1 specific) |
| `min_area` | float[8] | µm² | DRC |
| `aux_rules` | object[] | µm | DRC (extra layer rules) |
| `enc_rules` | object[] | µm | DRC (enclosure checks) |
| `cross_rules` | object[] | µm | DRC (cross-layer spacing) |
| `layer_map` | int[8] | GDS layer | GDS exporter |
| `metal_direction` | string[8] | — | Router preferred direction |
| `layers` | object | — | GDS exporter, DRC, Liberty, PEX |

---

## How to Write a New PDK JSON

A new PDK JSON file must supply all of the above fields. Recommended process:

1. Identify your process PDK documentation for metal layer stack, via dimensions, and design rules.
2. Set `num_metal_layers` to the number of stackable routing metals.
3. Populate all 8-element arrays, setting unused indices to 0.0.
4. Map `layer_map[i]` to the GDS layer number for metal layer `i`.
5. Set `metal_direction` to alternating `"horizontal"/"vertical"` starting with your preferred direction for li or metal1.
6. Populate the `layers` object with every significant layer using `[gds_layer, gds_datatype]` pairs. For multi-metal or multi-via groups, use nested arrays.
7. Derive `aux_rules` from your PDK's contact/via DRC rules.
8. Derive `enc_rules` from your PDK's enclosure DRC rules (metal enclosing vias, etc.).
9. Derive `cross_rules` from any cross-layer spacing rules (poly-to-diffusion etc.).

---

## PDK JSON Schema Tree

```svg
<svg viewBox="0 0 900 820" xmlns="http://www.w3.org/2000/svg" font-family="'Inter', 'Segoe UI', sans-serif">
  <rect width="900" height="820" fill="#060C18"/>
  <text x="450" y="34" text-anchor="middle" fill="#00C4E8" font-size="18" font-weight="bold">PDK JSON Schema Tree — sky130</text>

  <defs>
    <marker id="tree" markerWidth="6" markerHeight="6" refX="5" refY="3" orient="auto">
      <path d="M0,0 L0,6 L6,3 z" fill="#14263E"/>
    </marker>
  </defs>

  <!-- Root node -->
  <rect x="380" y="50" width="140" height="36" rx="6" fill="#09111F" stroke="#00C4E8" stroke-width="2"/>
  <text x="450" y="73" text-anchor="middle" fill="#00C4E8" font-size="13" font-weight="bold">PDK JSON</text>

  <!-- ─── Identity branch ─── -->
  <line x1="380" y1="68" x2="200" y2="120" stroke="#14263E" stroke-width="1.2"/>
  <rect x="120" y="108" width="160" height="32" rx="4" fill="#09111F" stroke="#1E88E5" stroke-width="1.2"/>
  <text x="200" y="129" text-anchor="middle" fill="#1E88E5" font-size="11" font-weight="bold">Identity</text>

  <!-- Identity leaves -->
  <line x1="120" y1="124" x2="60" y2="162" stroke="#14263E" stroke-width="1"/>
  <rect x="20" y="152" width="130" height="48" rx="3" fill="#060C18" stroke="#14263E" stroke-width="1"/>
  <text x="85" y="170" text-anchor="middle" fill="#B8D0E8" font-size="9">name: string</text>
  <text x="85" y="184" text-anchor="middle" fill="#3E5E80" font-size="8">"sky130"</text>
  <text x="85" y="196" text-anchor="middle" fill="#3E5E80" font-size="8">PDK identifier</text>

  <line x1="120" y1="124" x2="200" y2="162" stroke="#14263E" stroke-width="1"/>
  <rect x="130" y="152" width="140" height="64" rx="3" fill="#060C18" stroke="#14263E" stroke-width="1"/>
  <text x="200" y="170" text-anchor="middle" fill="#B8D0E8" font-size="9">num_metal_layers: int</text>
  <text x="200" y="184" text-anchor="middle" fill="#3E5E80" font-size="8">5 (router)</text>
  <text x="200" y="198" text-anchor="middle" fill="#B8D0E8" font-size="9">db_unit: float</text>
  <text x="200" y="212" text-anchor="middle" fill="#3E5E80" font-size="8">0.001 µm/db_unit</text>

  <!-- ─── Router rules branch ─── -->
  <line x1="450" y1="86" x2="450" y2="120" stroke="#14263E" stroke-width="1.2"/>
  <rect x="360" y="108" width="180" height="32" rx="4" fill="#09111F" stroke="#1E88E5" stroke-width="1.2"/>
  <text x="450" y="129" text-anchor="middle" fill="#1E88E5" font-size="11" font-weight="bold">Router Rules (arrays[8])</text>

  <!-- Router leaves col 1 -->
  <line x1="380" y1="140" x2="280" y2="178" stroke="#14263E" stroke-width="1"/>
  <rect x="210" y="168" width="140" height="130" rx="3" fill="#060C18" stroke="#14263E" stroke-width="1"/>
  <text x="280" y="186" text-anchor="middle" fill="#B8D0E8" font-size="9" font-weight="bold">min_spacing float[8]</text>
  <text x="280" y="202" text-anchor="middle" fill="#3E5E80" font-size="8">[0.14, 0.14, 0.14, 0.28...]</text>
  <text x="280" y="216" text-anchor="middle" fill="#B8D0E8" font-size="9">min_width float[8]</text>
  <text x="280" y="230" text-anchor="middle" fill="#3E5E80" font-size="8">[0.14, 0.14, 0.14, 0.30...]</text>
  <text x="280" y="244" text-anchor="middle" fill="#B8D0E8" font-size="9">metal_pitch float[8]</text>
  <text x="280" y="258" text-anchor="middle" fill="#3E5E80" font-size="8">[0.34, 0.34, 0.46, 0.68...]</text>
  <text x="280" y="272" text-anchor="middle" fill="#B8D0E8" font-size="9">tile_size float</text>
  <text x="280" y="286" text-anchor="middle" fill="#3E5E80" font-size="8">1.0 µm (grid cell)</text>

  <!-- Router leaves col 2 -->
  <line x1="520" y1="140" x2="570" y2="178" stroke="#14263E" stroke-width="1"/>
  <rect x="500" y="168" width="140" height="130" rx="3" fill="#060C18" stroke="#14263E" stroke-width="1"/>
  <text x="570" y="186" text-anchor="middle" fill="#B8D0E8" font-size="9" font-weight="bold">via_width float[8]</text>
  <text x="570" y="202" text-anchor="middle" fill="#3E5E80" font-size="8">[0.17, 0.17, 0.15, 0.20...]</text>
  <text x="570" y="216" text-anchor="middle" fill="#B8D0E8" font-size="9">min_enclosure float[8]</text>
  <text x="570" y="230" text-anchor="middle" fill="#3E5E80" font-size="8">[0.08, 0.03, 0.055...]</text>
  <text x="570" y="244" text-anchor="middle" fill="#B8D0E8" font-size="9">metal_direction str[8]</text>
  <text x="570" y="258" text-anchor="middle" fill="#3E5E80" font-size="8">["horizontal","vertical"...]</text>
  <text x="570" y="272" text-anchor="middle" fill="#B8D0E8" font-size="9">layer_map int[8]</text>
  <text x="570" y="286" text-anchor="middle" fill="#3E5E80" font-size="8">[67, 68, 69, 70, 71...]</text>

  <!-- ─── DRC branch ─── -->
  <line x1="520" y1="68" x2="730" y2="120" stroke="#14263E" stroke-width="1.2"/>
  <rect x="660" y="108" width="140" height="32" rx="4" fill="#09111F" stroke="#EF5350" stroke-width="1.2"/>
  <text x="730" y="129" text-anchor="middle" fill="#EF5350" font-size="11" font-weight="bold">DRC Rules</text>

  <!-- DRC leaves -->
  <line x1="660" y1="124" x2="600" y2="162" stroke="#14263E" stroke-width="1"/>
  <rect x="530" y="152" width="140" height="80" rx="3" fill="#060C18" stroke="#14263E" stroke-width="1"/>
  <text x="600" y="170" text-anchor="middle" fill="#B8D0E8" font-size="9" font-weight="bold">min_area float[8]</text>
  <text x="600" y="186" text-anchor="middle" fill="#3E5E80" font-size="8">[0.083, 0.0676, 0.24...]</text>
  <text x="600" y="200" text-anchor="middle" fill="#B8D0E8" font-size="9">same_net_spacing float[8]</text>
  <text x="600" y="216" text-anchor="middle" fill="#3E5E80" font-size="8">[0.14, 0.14, 0.14, 0.28...]</text>

  <line x1="800" y1="124" x2="820" y2="162" stroke="#14263E" stroke-width="1"/>
  <rect x="740" y="152" width="145" height="112" rx="3" fill="#060C18" stroke="#14263E" stroke-width="1"/>
  <text x="812" y="170" text-anchor="middle" fill="#EF5350" font-size="9" font-weight="bold">aux_rules[ ]</text>
  <text x="812" y="186" text-anchor="middle" fill="#3E5E80" font-size="8">gds_layer, gds_datatype</text>
  <text x="812" y="200" text-anchor="middle" fill="#3E5E80" font-size="8">min_width, min_spacing</text>
  <text x="812" y="214" text-anchor="middle" fill="#3E5E80" font-size="8">min_area (7 entries)</text>
  <text x="812" y="232" text-anchor="middle" fill="#EF5350" font-size="9" font-weight="bold">enc_rules[ ]</text>
  <text x="812" y="248" text-anchor="middle" fill="#3E5E80" font-size="8">outer/inner layer pairs</text>
  <text x="812" y="262" text-anchor="middle" fill="#3E5E80" font-size="8">enclosure µm (11 entries)</text>

  <!-- cross_rules -->
  <line x1="740" y1="268" x2="680" y2="300" stroke="#14263E" stroke-width="1"/>
  <rect x="590" y="290" width="180" height="64" rx="3" fill="#060C18" stroke="#14263E" stroke-width="1"/>
  <text x="680" y="310" text-anchor="middle" fill="#EF5350" font-size="9" font-weight="bold">cross_rules[ ]</text>
  <text x="680" y="326" text-anchor="middle" fill="#3E5E80" font-size="8">layer_a / layer_b pairs</text>
  <text x="680" y="342" text-anchor="middle" fill="#3E5E80" font-size="8">min_spacing µm (7 entries)</text>

  <!-- ─── layers object branch ─── -->
  <line x1="450" y1="86" x2="240" y2="380" stroke="#14263E" stroke-width="1.2"/>
  <rect x="140" y="368" width="200" height="32" rx="4" fill="#09111F" stroke="#00C4E8" stroke-width="1.2"/>
  <text x="240" y="389" text-anchor="middle" fill="#00C4E8" font-size="11" font-weight="bold">layers{} object</text>

  <!-- Layers leaves -->
  <rect x="30" y="418" width="420" height="200" rx="4" fill="#060C18" stroke="#14263E" stroke-width="1"/>
  <line x1="240" y1="400" x2="240" y2="418" stroke="#14263E" stroke-width="1"/>

  <text x="50" y="438" fill="#43A047" font-size="9" font-weight="bold">Device layers (router=blue, DRC=red):</text>
  <text x="50" y="456" fill="#B8D0E8" font-size="9">nwell   [64,20]  — PMOS body N-well</text>
  <text x="50" y="472" fill="#B8D0E8" font-size="9">diff    [65,20]  — MOSFET active diffusion</text>
  <text x="50" y="488" fill="#B8D0E8" font-size="9">tap     [65,44]  — body contact tap</text>
  <text x="50" y="504" fill="#B8D0E8" font-size="9">poly    [66,20]  — polysilicon gate</text>
  <text x="50" y="520" fill="#B8D0E8" font-size="9">nsdm    [93,44]  — N-implant mask</text>
  <text x="50" y="536" fill="#B8D0E8" font-size="9">psdm    [94,20]  — P-implant mask</text>

  <text x="240" y="456" fill="#1E88E5" font-size="9" font-weight="bold">Routing layers:</text>
  <text x="240" y="472" fill="#B8D0E8" font-size="9">licon   [66,44]  — contact to li1</text>
  <text x="240" y="488" fill="#B8D0E8" font-size="9">li      [67,20]  — local interconnect</text>
  <text x="240" y="504" fill="#B8D0E8" font-size="9">mcon    [67,44]  — li1-to-met1 contact</text>
  <text x="240" y="520" fill="#B8D0E8" font-size="9">metal   [[68..72],20] — met1-met5</text>
  <text x="240" y="536" fill="#B8D0E8" font-size="9">via     [[68..71],44] — via1-via4</text>
  <text x="240" y="552" fill="#B8D0E8" font-size="9">li_pin  [67,5]   — pin labels on li1</text>
  <text x="240" y="568" fill="#B8D0E8" font-size="9">metal_pin [[68..72],5] — pin labels on metals</text>

  <!-- ─── LI rules branch ─── -->
  <line x1="450" y1="86" x2="680" y2="380" stroke="#14263E" stroke-width="1.2"/>
  <rect x="590" y="368" width="200" height="32" rx="4" fill="#09111F" stroke="#AB47BC" stroke-width="1.2"/>
  <text x="690" y="389" text-anchor="middle" fill="#AB47BC" font-size="11" font-weight="bold">LI-specific rules</text>

  <rect x="590" y="418" width="200" height="80" rx="3" fill="#060C18" stroke="#14263E" stroke-width="1"/>
  <line x1="690" y1="400" x2="690" y2="418" stroke="#14263E" stroke-width="1"/>
  <text x="690" y="438" text-anchor="middle" fill="#B8D0E8" font-size="9">li_min_spacing: 0.17 µm</text>
  <text x="690" y="456" text-anchor="middle" fill="#B8D0E8" font-size="9">li_min_width:   0.17 µm</text>
  <text x="690" y="474" text-anchor="middle" fill="#B8D0E8" font-size="9">li_min_area:    0.0561 µm²</text>
  <text x="690" y="492" text-anchor="middle" fill="#3E5E80" font-size="8">(local interconnect only)</text>

  <!-- ─── param_to_um branch ─── -->
  <rect x="360" y="640" width="180" height="56" rx="4" fill="#060C18" stroke="#FB8C00" stroke-width="1.2"/>
  <text x="450" y="660" text-anchor="middle" fill="#FB8C00" font-size="10" font-weight="bold">param_to_um: 1000000.0</text>
  <text x="450" y="678" text-anchor="middle" fill="#3E5E80" font-size="9">SPICE W/L (meters) → µm</text>
  <text x="450" y="692" text-anchor="middle" fill="#3E5E80" font-size="9">consumed by placer/lib.zig</text>
  <line x1="450" y1="86" x2="450" y2="640" stroke="#14263E" stroke-width="0.8" stroke-dasharray="5,4"/>

  <!-- Legend -->
  <rect x="30" y="750" width="840" height="56" rx="6" fill="#09111F" stroke="#14263E" stroke-width="1"/>
  <text x="60" y="772" fill="#1E88E5" font-size="10" font-weight="bold">■ Router</text>
  <text x="140" y="772" fill="#EF5350" font-size="10" font-weight="bold">■ DRC / LVS</text>
  <text x="240" y="772" fill="#43A047" font-size="10" font-weight="bold">■ Device layer</text>
  <text x="350" y="772" fill="#00C4E8" font-size="10" font-weight="bold">■ Layer map</text>
  <text x="450" y="772" fill="#AB47BC" font-size="10" font-weight="bold">■ LI-specific</text>
  <text x="560" y="772" fill="#FB8C00" font-size="10" font-weight="bold">■ Liberty / Placer</text>
  <text x="60" y="793" fill="#3E5E80" font-size="9">All numeric values in µm unless noted. Arrays are 8 elements; indices 0..num_metal_layers-1 are used.</text>
</svg>
```
