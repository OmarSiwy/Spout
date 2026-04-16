# sky130 Layer Stack — Complete PDK Layer Reference

> **Source:** `pdks/sky130.json`, `src/router/DRC_RULES.md`, `RESEARCH.md`

---

## 1. PDK Identification

| Property | Value |
|---|---|
| **PDK name** | `sky130` |
| **Number of metal layers** | 5 (LI + M1–M5) |
| **Database unit** | 0.001 µm (1 nm per GDS unit) |
| **SPICE parameter scale** | 1,000,000 (SPICE values in meters → layout in µm) |
| **Tile size** | 1.0 µm |
| **Variants** | sky130A, sky130B |
| **Supported by** | Spout, Magic, KLayout, OpenROAD |

---

## 2. Complete Layer Table

### 2.1 Active / Device Layers

| Layer Name | GDS Layer | GDS Datatype | Min Width | Min Spacing | Role |
|---|---|---|---|---|---|
| `nwell` | 64 | 20 | 0.84 µm | 1.27 µm | N-type well for PMOS body |
| `diff` | 65 | 20 | 0.26 µm | 0.27 µm | Active diffusion (source/drain/gate active area) |
| `tap` | 65 | 44 | 0.17 µm | 0.27 µm | Body/well tap contact diffusion |
| `poly` | 66 | 20 | 0.15 µm | 0.21 µm | Poly silicon gate |
| `nsdm` | 93 | 44 | — | — | N+ source/drain implant mask |
| `psdm` | 94 | 20 | — | — | P+ source/drain implant mask |
| `npc` | 95 | 20 | — | — | Nitride poly cut (salicide block) |

### 2.2 Contact / Via Layers

| Layer Name | GDS Layer | GDS Datatype | Min Width | Min Spacing | Connects |
|---|---|---|---|---|---|
| `licon` | 66 | 44 | 0.17 µm | 0.17 µm | poly/diff → LI |
| `mcon` | 67 | 44 | 0.17 µm | 0.19 µm | LI → M1 |
| `via1` | 68 | 44 | 0.15 µm | 0.17 µm | M1 → M2 |
| `via2` | 69 | 44 | 0.15 µm | 0.17 µm | M2 → M3 |
| `via3` | 70 | 44 | 0.20 µm | 0.20 µm | M3 → M4 |
| `via4` | 71 | 44 | 0.20 µm | 0.20 µm | M4 → M5 |

### 2.3 Interconnect Layers

| Layer Name | GDS Layer | GDS Datatype | Min Width | Min Spacing | Metal Pitch | Preferred Direction | Sheet R |
|---|---|---|---|---|---|---|---|
| `li` | 67 | 20 | 0.17 µm | 0.17 µm | — | horizontal | — |
| `metal1` (M1) | 68 | 20 | 0.14 µm | 0.14 µm | 0.34 µm | horizontal | — |
| `metal2` (M2) | 69 | 20 | 0.14 µm | 0.14 µm | 0.34 µm | vertical | — |
| `metal3` (M3) | 70 | 20 | 0.14 µm | 0.14 µm | 0.46 µm | horizontal | — |
| `metal4` (M4) | 71 | 20 | 0.30 µm | 0.28 µm | 0.68 µm | vertical | — |
| `metal5` (M5) | 72 | 20 | 0.30 µm | 0.28 µm | 0.68 µm | horizontal | — |

**Note:** sky130's 5-metal stack is LI + 5 true metals. LI (local interconnect) is a thin tungsten layer used for local connections between devices. The Spout routing layer index maps LI as index 0, M1 as index 1, etc.

### 2.4 Pin Layers (GDS export only)

| Layer Name | GDS Layer | GDS Datatype | Use |
|---|---|---|---|
| `li_pin` | 67 | 5 | LI pin shape for LVS port recognition |
| `metal1_pin` | 68 | 5 | M1 pin shape |
| `metal2_pin` | 69 | 5 | M2 pin shape |
| `metal3_pin` | 70 | 5 | M3 pin shape |
| `metal4_pin` | 71 | 5 | M4 pin shape |
| `metal5_pin` | 72 | 5 | M5 pin shape |

---

## 3. Routing Layer Index Convention

Spout's `RouteArrays.layer` field uses a compact integer index:

| Route Layer Index | PDK Layer | GDS Layer | GDS Datatype |
|---|---|---|---|
| 0 | LI | 67 | 20 |
| 1 | M1 | 68 | 20 |
| 2 | M2 | 69 | 20 |
| 3 | M3 | 70 | 20 |
| 4 | M4 | 71 | 20 |
| 5 | M5 | 72 | 20 |

**PDK config array indexing:** `min_width`, `min_spacing`, `metal_pitch`, `same_net_spacing`, `min_area`, and `via_width` arrays use index 0 for M1 (not LI). The LI rules are in separate fields `li_min_width`, `li_min_spacing`, `li_min_area`. When routing layer index `i` maps to M1 (route index 1), the PDK array index is `i - 1`.

---

## 4. Design Rules Summary

### 4.1 Min Width

```json
"min_width": [0.14, 0.14, 0.14, 0.30, 0.30, 1.6, 0.0, 0.0]
```

Indices: [M1, M2, M3, M4, M5, ?, -, -]

| Layer | Min Width |
|---|---|
| LI | 0.17 µm |
| M1 | 0.14 µm |
| M2 | 0.14 µm |
| M3 | 0.14 µm |
| M4 | 0.30 µm |
| M5 | 0.30 µm |
| poly | 0.15 µm |
| diff | 0.26 µm |
| nwell | 0.84 µm |

### 4.2 Min Spacing

```json
"min_spacing": [0.14, 0.14, 0.14, 0.28, 0.28, 1.6, 0.0, 0.0]
```

| Layer | Min Spacing |
|---|---|
| LI | 0.17 µm |
| M1 | 0.14 µm |
| M2 | 0.14 µm |
| M3 | 0.14 µm |
| M4 | 0.28 µm |
| M5 | 0.28 µm |
| poly | 0.21 µm |
| diff | 0.27 µm |
| nwell | 1.27 µm |

### 4.3 Via Enclosure Summary

| Via Cut | Metal Enclosing | Enclosure |
|---|---|---|
| licon (66/44) | poly (66/20) | 0.0 µm (no rule) |
| licon (66/44) | diff (65/20) | 0.04 µm |
| licon (66/44) | diff (65/20) | 0.12 µm (alternate rule) |
| licon (66/44) | tap (65/44) | 0.12 µm |
| licon (66/44) | LI (67/20) | 0.08 µm |
| licon (66/44) | M1 (68/20) | 0.06 µm |
| mcon (67/44) | M1 (68/20) | 0.06 µm |
| via1 (68/44) | M1 (68/20) | 0.03 µm |
| via1 (68/44) | M2 (69/20) | 0.03 µm |
| via2 (69/44) | M2 (69/20) | 0.055 µm |
| tap (65/44) | nwell (64/20) | 0.18 µm |

### 4.4 Min Area

```json
"min_area": [0.083, 0.0676, 0.24, 0.24, 4.0, 0.0, 0.0, 0.0]
```

| Layer | Min Area |
|---|---|
| LI | 0.0561 µm² |
| M1 | 0.083 µm² |
| M2 | 0.0676 µm² |
| M3 | 0.24 µm² |
| M4 | 0.24 µm² |
| M5 | 4.0 µm² |

### 4.5 Metal Pitch

```json
"metal_pitch": [0.34, 0.34, 0.46, 0.68, 0.68, 3.4, 0.0, 0.0]
```

| Layer | Metal Pitch | Implies Track Density |
|---|---|---|
| M1 | 0.34 µm | ≈ 2.94 tracks/µm |
| M2 | 0.34 µm | ≈ 2.94 tracks/µm |
| M3 | 0.46 µm | ≈ 2.17 tracks/µm |
| M4 | 0.68 µm | ≈ 1.47 tracks/µm |
| M5 | 0.68 µm | ≈ 1.47 tracks/µm |

---

## 5. Layer Stack Cross-Section SVG

```svg
<svg viewBox="0 0 900 500" xmlns="http://www.w3.org/2000/svg" font-family="'Inter','Segoe UI',sans-serif">
  <!-- Background -->
  <rect width="900" height="500" fill="#060C18"/>
  <text x="450" y="28" fill="#B8D0E8" font-size="17" font-weight="bold" text-anchor="middle">sky130 Metal Stack — Layer Cross-Section</text>

  <!-- ── Substrate ── -->
  <rect x="60" y="448" width="700" height="35" rx="3" fill="#1a0a00" stroke="#FB8C00" stroke-width="1.5"/>
  <text x="410" y="470" fill="#FB8C00" font-size="12" text-anchor="middle">Silicon Substrate (p-type bulk)</text>
  <text x="790" y="462" fill="#3E5E80" font-size="10">GDS —</text>
  <text x="790" y="476" fill="#3E5E80" font-size="10">substrate</text>

  <!-- ── nwell ── -->
  <rect x="60" y="410" width="200" height="34" rx="3" fill="#FF6B9D" fill-opacity="0.3" stroke="#FF6B9D" stroke-width="1.5"/>
  <text x="160" y="431" fill="#FF6B9D" font-size="11" text-anchor="middle">nwell</text>
  <text x="790" y="422" fill="#3E5E80" font-size="10">GDS 64/20</text>
  <text x="790" y="436" fill="#3E5E80" font-size="10">0.84µm min-w</text>

  <!-- ── diff / tap ── -->
  <rect x="60" y="372" width="130" height="34" rx="3" fill="#43A047" fill-opacity="0.6" stroke="#43A047" stroke-width="1.5"/>
  <text x="125" y="393" fill="#fff" font-size="11" text-anchor="middle">diff</text>
  <rect x="200" y="372" width="60" height="34" rx="3" fill="#43A047" fill-opacity="0.4" stroke="#43A047" stroke-dasharray="4,3"/>
  <text x="230" y="393" fill="#43A047" font-size="10" text-anchor="middle">tap</text>
  <text x="790" y="383" fill="#3E5E80" font-size="10">diff: GDS 65/20</text>
  <text x="790" y="397" fill="#3E5E80" font-size="10">tap: GDS 65/44</text>

  <!-- ── poly ── -->
  <rect x="90" y="334" width="60" height="34" rx="3" fill="#EF5350" fill-opacity="0.8" stroke="#EF5350" stroke-width="1.5"/>
  <text x="120" y="355" fill="#fff" font-size="11" text-anchor="middle">poly</text>
  <text x="790" y="344" fill="#3E5E80" font-size="10">GDS 66/20</text>
  <text x="790" y="358" fill="#3E5E80" font-size="10">0.15µm min-w</text>

  <!-- ── licon dots ── -->
  <circle cx="125" cy="325" r="5" fill="#FB8C00"/>
  <circle cx="155" cy="325" r="5" fill="#FB8C00"/>
  <circle cx="215" cy="325" r="5" fill="#FB8C00"/>
  <text x="790" y="322" fill="#3E5E80" font-size="10">licon: GDS 66/44</text>
  <text x="790" y="334" fill="#3E5E80" font-size="10">0.17µm min-w</text>

  <!-- ── LI ── -->
  <rect x="60" y="288" width="700" height="30" rx="3" fill="#78909C" fill-opacity="0.7" stroke="#90A4AE" stroke-width="1.5"/>
  <text x="410" y="307" fill="#fff" font-size="11" text-anchor="middle">LI — Local Interconnect</text>
  <text x="790" y="298" fill="#3E5E80" font-size="10">GDS 67/20</text>
  <text x="790" y="312" fill="#3E5E80" font-size="10">0.17µm min-w</text>

  <!-- ── mcon dots ── -->
  <circle cx="125" cy="280" r="5" fill="#FB8C00"/>
  <circle cx="230" cy="280" r="5" fill="#FB8C00"/>
  <circle cx="410" cy="280" r="5" fill="#FB8C00"/>
  <text x="790" y="276" fill="#3E5E80" font-size="10">mcon: GDS 67/44</text>
  <text x="790" y="288" fill="#3E5E80" font-size="10">0.17µm min-w</text>

  <!-- ── M1 ── -->
  <rect x="60" y="240" width="700" height="33" rx="3" fill="#1E88E5" fill-opacity="0.85" stroke="#1E88E5" stroke-width="1.5"/>
  <text x="410" y="260" fill="#fff" font-size="12" font-weight="bold" text-anchor="middle">Metal 1 (M1)</text>
  <text x="790" y="250" fill="#3E5E80" font-size="10">GDS 68/20</text>
  <text x="790" y="264" fill="#3E5E80" font-size="10">0.14µm min-w  0.34µm pitch</text>

  <!-- ── via1 squares ── -->
  <rect x="122" y="231" width="10" height="8" fill="#FB8C00"/>
  <rect x="290" y="231" width="10" height="8" fill="#FB8C00"/>
  <rect x="530" y="231" width="10" height="8" fill="#FB8C00"/>
  <text x="790" y="228" fill="#3E5E80" font-size="10">via1: GDS 68/44</text>
  <text x="790" y="240" fill="#3E5E80" font-size="10">0.15µm min-w</text>

  <!-- ── M2 ── -->
  <rect x="60" y="193" width="700" height="33" rx="3" fill="#1E88E5" fill-opacity="0.65" stroke="#42A5F5" stroke-width="1.5"/>
  <text x="410" y="213" fill="#fff" font-size="12" font-weight="bold" text-anchor="middle">Metal 2 (M2)</text>
  <text x="790" y="203" fill="#3E5E80" font-size="10">GDS 69/20</text>
  <text x="790" y="217" fill="#3E5E80" font-size="10">0.14µm min-w  0.34µm pitch</text>

  <!-- ── via2 squares ── -->
  <rect x="200" y="184" width="10" height="8" fill="#FB8C00"/>
  <rect x="420" y="184" width="10" height="8" fill="#FB8C00"/>
  <text x="790" y="182" fill="#3E5E80" font-size="10">via2: GDS 69/44</text>

  <!-- ── M3 ── -->
  <rect x="60" y="147" width="700" height="32" rx="3" fill="#AB47BC" fill-opacity="0.7" stroke="#AB47BC" stroke-width="1.5"/>
  <text x="410" y="167" fill="#fff" font-size="12" font-weight="bold" text-anchor="middle">Metal 3 (M3)</text>
  <text x="790" y="157" fill="#3E5E80" font-size="10">GDS 70/20</text>
  <text x="790" y="171" fill="#3E5E80" font-size="10">0.14µm min-w  0.46µm pitch</text>

  <!-- ── via3 squares ── -->
  <rect x="300" y="138" width="12" height="8" fill="#FB8C00"/>
  <rect x="500" y="138" width="12" height="8" fill="#FB8C00"/>

  <!-- ── M4 ── -->
  <rect x="60" y="102" width="700" height="32" rx="3" fill="#7E57C2" fill-opacity="0.7" stroke="#9575CD" stroke-width="1.5"/>
  <text x="410" y="122" fill="#fff" font-size="12" font-weight="bold" text-anchor="middle">Metal 4 (M4)</text>
  <text x="790" y="112" fill="#3E5E80" font-size="10">GDS 71/20</text>
  <text x="790" y="126" fill="#3E5E80" font-size="10">0.30µm min-w  0.68µm pitch</text>

  <!-- ── via4 squares ── -->
  <rect x="380" y="93" width="12" height="8" fill="#FB8C00"/>

  <!-- ── M5 ── -->
  <rect x="60" y="56" width="700" height="32" rx="3" fill="#5C6BC0" fill-opacity="0.7" stroke="#7986CB" stroke-width="1.5"/>
  <text x="410" y="76" fill="#fff" font-size="12" font-weight="bold" text-anchor="middle">Metal 5 (M5)</text>
  <text x="790" y="66" fill="#3E5E80" font-size="10">GDS 72/20</text>
  <text x="790" y="80" fill="#3E5E80" font-size="10">0.30µm min-w  0.68µm pitch</text>

  <!-- Scale indicator -->
  <line x1="60" y1="492" x2="110" y2="492" stroke="#00C4E8" stroke-width="1.5" marker-end="url(#a2)" marker-start="url(#a2l)"/>
  <text x="85" y="488" fill="#00C4E8" font-size="9" text-anchor="middle">≈50 DB units</text>

  <defs>
    <marker id="a2" markerWidth="6" markerHeight="5" refX="5" refY="2.5" orient="auto">
      <path d="M0,0 L6,2.5 L0,5 Z" fill="#00C4E8"/>
    </marker>
    <marker id="a2l" markerWidth="6" markerHeight="5" refX="1" refY="2.5" orient="auto-start-reverse">
      <path d="M0,0 L6,2.5 L0,5 Z" fill="#00C4E8"/>
    </marker>
  </defs>
</svg>
```

---

## 6. Design Rules Heatmap

```svg
<svg viewBox="0 0 900 400" xmlns="http://www.w3.org/2000/svg" font-family="'Inter','Segoe UI',sans-serif">
  <rect width="900" height="400" fill="#060C18"/>
  <text x="450" y="28" fill="#B8D0E8" font-size="16" font-weight="bold" text-anchor="middle">sky130 Design Rules Summary — Layer vs. Rule Type</text>

  <!-- Column headers (rule types) -->
  <text x="210" y="58" fill="#00C4E8" font-size="10" text-anchor="middle">Min Width</text>
  <text x="310" y="58" fill="#00C4E8" font-size="10" text-anchor="middle">Min Space</text>
  <text x="410" y="58" fill="#00C4E8" font-size="10" text-anchor="middle">Metal Pitch</text>
  <text x="510" y="58" fill="#00C4E8" font-size="10" text-anchor="middle">Min Enclosure</text>
  <text x="610" y="58" fill="#00C4E8" font-size="10" text-anchor="middle">Via Width</text>
  <text x="710" y="58" fill="#00C4E8" font-size="10" text-anchor="middle">Min Area</text>
  <text x="810" y="58" fill="#00C4E8" font-size="10" text-anchor="middle">Same-Net Spc</text>

  <!-- Row labels (layers) -->
  <text x="130" y="90" fill="#B8D0E8" font-size="11" text-anchor="end">LI (local)</text>
  <text x="130" y="130" fill="#1E88E5" font-size="11" text-anchor="end">M1</text>
  <text x="130" y="170" fill="#1E88E5" font-size="11" text-anchor="end">M2</text>
  <text x="130" y="210" fill="#AB47BC" font-size="11" text-anchor="end">M3</text>
  <text x="130" y="250" fill="#7E57C2" font-size="11" text-anchor="end">M4</text>
  <text x="130" y="290" fill="#5C6BC0" font-size="11" text-anchor="end">M5</text>
  <text x="130" y="330" fill="#EF5350" font-size="11" text-anchor="end">poly</text>
  <text x="130" y="370" fill="#43A047" font-size="11" text-anchor="end">diff</text>

  <!-- Helper macro: each cell is 80px wide, 30px tall, starting x=140+col*100, y=65+row*40 -->
  <!-- LI row (index 0) -->
  <rect x="145" y="68" width="90" height="28" rx="3" fill="#1a2540" stroke="#1E88E5" stroke-width="0.5"/>
  <text x="190" y="85" fill="#B8D0E8" font-size="11" text-anchor="middle">0.17</text>

  <rect x="245" y="68" width="90" height="28" rx="3" fill="#1a2540" stroke="#1E88E5" stroke-width="0.5"/>
  <text x="290" y="85" fill="#B8D0E8" font-size="11" text-anchor="middle">0.17</text>

  <rect x="345" y="68" width="90" height="28" rx="3" fill="#0c1520" stroke="#14263E" stroke-width="0.5"/>
  <text x="390" y="85" fill="#3E5E80" font-size="10" text-anchor="middle">—</text>

  <rect x="445" y="68" width="90" height="28" rx="3" fill="#0c1520" stroke="#14263E" stroke-width="0.5"/>
  <text x="490" y="85" fill="#3E5E80" font-size="10" text-anchor="middle">0.08</text>

  <rect x="545" y="68" width="90" height="28" rx="3" fill="#0c1520" stroke="#14263E" stroke-width="0.5"/>
  <text x="590" y="85" fill="#3E5E80" font-size="10" text-anchor="middle">0.17</text>

  <rect x="645" y="68" width="90" height="28" rx="3" fill="#1a2015" stroke="#43A047" stroke-width="0.5"/>
  <text x="690" y="85" fill="#B8D0E8" font-size="11" text-anchor="middle">0.0561</text>

  <rect x="745" y="68" width="90" height="28" rx="3" fill="#1a2540" stroke="#1E88E5" stroke-width="0.5"/>
  <text x="790" y="85" fill="#B8D0E8" font-size="11" text-anchor="middle">0.17</text>

  <!-- M1 row -->
  <rect x="145" y="108" width="90" height="28" rx="3" fill="#0e2045" stroke="#1E88E5" stroke-width="1"/>
  <text x="190" y="125" fill="#90CAF9" font-size="11" text-anchor="middle">0.14</text>

  <rect x="245" y="108" width="90" height="28" rx="3" fill="#0e2045" stroke="#1E88E5" stroke-width="1"/>
  <text x="290" y="125" fill="#90CAF9" font-size="11" text-anchor="middle">0.14</text>

  <rect x="345" y="108" width="90" height="28" rx="3" fill="#0e2045" stroke="#1E88E5" stroke-width="1"/>
  <text x="390" y="125" fill="#90CAF9" font-size="11" text-anchor="middle">0.34</text>

  <rect x="445" y="108" width="90" height="28" rx="3" fill="#1a1030" stroke="#AB47BC" stroke-width="0.5"/>
  <text x="490" y="125" fill="#CE93D8" font-size="11" text-anchor="middle">0.03</text>

  <rect x="545" y="108" width="90" height="28" rx="3" fill="#1a1a08" stroke="#FB8C00" stroke-width="0.5"/>
  <text x="590" y="125" fill="#FFCC80" font-size="11" text-anchor="middle">0.17</text>

  <rect x="645" y="108" width="90" height="28" rx="3" fill="#0e2045" stroke="#1E88E5" stroke-width="1"/>
  <text x="690" y="125" fill="#90CAF9" font-size="11" text-anchor="middle">0.083</text>

  <rect x="745" y="108" width="90" height="28" rx="3" fill="#0e2045" stroke="#1E88E5" stroke-width="1"/>
  <text x="790" y="125" fill="#90CAF9" font-size="11" text-anchor="middle">0.14</text>

  <!-- M2 row -->
  <rect x="145" y="148" width="90" height="28" rx="3" fill="#0e2045" stroke="#1E88E5" stroke-width="0.7"/>
  <text x="190" y="165" fill="#90CAF9" font-size="11" text-anchor="middle">0.14</text>
  <rect x="245" y="148" width="90" height="28" rx="3" fill="#0e2045" stroke="#1E88E5" stroke-width="0.7"/>
  <text x="290" y="165" fill="#90CAF9" font-size="11" text-anchor="middle">0.14</text>
  <rect x="345" y="148" width="90" height="28" rx="3" fill="#0e2045" stroke="#1E88E5" stroke-width="0.7"/>
  <text x="390" y="165" fill="#90CAF9" font-size="11" text-anchor="middle">0.34</text>
  <rect x="445" y="148" width="90" height="28" rx="3" fill="#1a1030" stroke="#AB47BC" stroke-width="0.5"/>
  <text x="490" y="165" fill="#CE93D8" font-size="11" text-anchor="middle">0.055</text>
  <rect x="545" y="148" width="90" height="28" rx="3" fill="#1a1a08" stroke="#FB8C00" stroke-width="0.5"/>
  <text x="590" y="165" fill="#FFCC80" font-size="11" text-anchor="middle">0.15</text>
  <rect x="645" y="148" width="90" height="28" rx="3" fill="#0e2045" stroke="#1E88E5" stroke-width="0.7"/>
  <text x="690" y="165" fill="#90CAF9" font-size="11" text-anchor="middle">0.0676</text>
  <rect x="745" y="148" width="90" height="28" rx="3" fill="#0e2045" stroke="#1E88E5" stroke-width="0.7"/>
  <text x="790" y="165" fill="#90CAF9" font-size="11" text-anchor="middle">0.14</text>

  <!-- M3 row -->
  <rect x="145" y="188" width="90" height="28" rx="3" fill="#150e35" stroke="#AB47BC" stroke-width="0.7"/>
  <text x="190" y="205" fill="#CE93D8" font-size="11" text-anchor="middle">0.14</text>
  <rect x="245" y="188" width="90" height="28" rx="3" fill="#150e35" stroke="#AB47BC" stroke-width="0.7"/>
  <text x="290" y="205" fill="#CE93D8" font-size="11" text-anchor="middle">0.14</text>
  <rect x="345" y="188" width="90" height="28" rx="3" fill="#150e35" stroke="#AB47BC" stroke-width="0.7"/>
  <text x="390" y="205" fill="#CE93D8" font-size="11" text-anchor="middle">0.46</text>
  <rect x="445" y="188" width="90" height="28" rx="3" fill="#150e35" stroke="#AB47BC" stroke-width="0.7"/>
  <text x="490" y="205" fill="#CE93D8" font-size="11" text-anchor="middle">0.065</text>
  <rect x="545" y="188" width="90" height="28" rx="3" fill="#1a1a08" stroke="#FB8C00" stroke-width="0.5"/>
  <text x="590" y="205" fill="#FFCC80" font-size="11" text-anchor="middle">0.20</text>
  <rect x="645" y="188" width="90" height="28" rx="3" fill="#150e35" stroke="#AB47BC" stroke-width="0.7"/>
  <text x="690" y="205" fill="#CE93D8" font-size="11" text-anchor="middle">0.24</text>
  <rect x="745" y="188" width="90" height="28" rx="3" fill="#150e35" stroke="#AB47BC" stroke-width="0.7"/>
  <text x="790" y="205" fill="#CE93D8" font-size="11" text-anchor="middle">0.14</text>

  <!-- M4 row -->
  <rect x="145" y="228" width="90" height="28" rx="3" fill="#0e0e2a" stroke="#7E57C2" stroke-width="0.7"/>
  <text x="190" y="245" fill="#B39DDB" font-size="11" text-anchor="middle">0.30</text>
  <rect x="245" y="228" width="90" height="28" rx="3" fill="#0e0e2a" stroke="#7E57C2" stroke-width="0.7"/>
  <text x="290" y="245" fill="#B39DDB" font-size="11" text-anchor="middle">0.28</text>
  <rect x="345" y="228" width="90" height="28" rx="3" fill="#0e0e2a" stroke="#7E57C2" stroke-width="0.7"/>
  <text x="390" y="245" fill="#B39DDB" font-size="11" text-anchor="middle">0.68</text>
  <rect x="445" y="228" width="90" height="28" rx="3" fill="#0e0e2a" stroke="#7E57C2" stroke-width="0.7"/>
  <text x="490" y="245" fill="#B39DDB" font-size="11" text-anchor="middle">0.065</text>
  <rect x="545" y="228" width="90" height="28" rx="3" fill="#1a1a08" stroke="#FB8C00" stroke-width="0.5"/>
  <text x="590" y="245" fill="#FFCC80" font-size="11" text-anchor="middle">0.20</text>
  <rect x="645" y="228" width="90" height="28" rx="3" fill="#0e0e2a" stroke="#7E57C2" stroke-width="0.7"/>
  <text x="690" y="245" fill="#B39DDB" font-size="11" text-anchor="middle">0.24</text>
  <rect x="745" y="228" width="90" height="28" rx="3" fill="#0e0e2a" stroke="#7E57C2" stroke-width="0.7"/>
  <text x="790" y="245" fill="#B39DDB" font-size="11" text-anchor="middle">0.28</text>

  <!-- M5 row -->
  <rect x="145" y="268" width="90" height="28" rx="3" fill="#0a0a22" stroke="#5C6BC0" stroke-width="0.7"/>
  <text x="190" y="285" fill="#9FA8DA" font-size="11" text-anchor="middle">0.30</text>
  <rect x="245" y="268" width="90" height="28" rx="3" fill="#0a0a22" stroke="#5C6BC0" stroke-width="0.7"/>
  <text x="290" y="285" fill="#9FA8DA" font-size="11" text-anchor="middle">0.28</text>
  <rect x="345" y="268" width="90" height="28" rx="3" fill="#0a0a22" stroke="#5C6BC0" stroke-width="0.7"/>
  <text x="390" y="285" fill="#9FA8DA" font-size="11" text-anchor="middle">0.68</text>
  <rect x="445" y="268" width="90" height="28" rx="3" fill="#0a0a22" stroke="#5C6BC0" stroke-width="0.7"/>
  <text x="490" y="285" fill="#9FA8DA" font-size="11" text-anchor="middle">0.31</text>
  <rect x="545" y="268" width="90" height="28" rx="3" fill="#0a0a22" stroke="#5C6BC0" stroke-width="0.7"/>
  <text x="590" y="285" fill="#9FA8DA" font-size="11" text-anchor="middle">0.80</text>
  <rect x="645" y="268" width="90" height="28" rx="3" fill="#0a0a22" stroke="#5C6BC0" stroke-width="0.7"/>
  <text x="690" y="285" fill="#9FA8DA" font-size="11" text-anchor="middle">4.0</text>
  <rect x="745" y="268" width="90" height="28" rx="3" fill="#0a0a22" stroke="#5C6BC0" stroke-width="0.7"/>
  <text x="790" y="285" fill="#9FA8DA" font-size="11" text-anchor="middle">0.28</text>

  <!-- poly row -->
  <rect x="145" y="308" width="90" height="28" rx="3" fill="#2a0808" stroke="#EF5350" stroke-width="0.7"/>
  <text x="190" y="325" fill="#EF9A9A" font-size="11" text-anchor="middle">0.15</text>
  <rect x="245" y="308" width="90" height="28" rx="3" fill="#2a0808" stroke="#EF5350" stroke-width="0.7"/>
  <text x="290" y="325" fill="#EF9A9A" font-size="11" text-anchor="middle">0.21</text>
  <rect x="345" y="308" width="90" height="28" rx="3" fill="#0c1520" stroke="#14263E" stroke-width="0.5"/>
  <text x="390" y="325" fill="#3E5E80" font-size="10" text-anchor="middle">—</text>
  <rect x="445" y="308" width="90" height="28" rx="3" fill="#0c1520" stroke="#14263E" stroke-width="0.5"/>
  <text x="490" y="325" fill="#3E5E80" font-size="10" text-anchor="middle">—</text>
  <rect x="545" y="308" width="90" height="28" rx="3" fill="#0c1520" stroke="#14263E" stroke-width="0.5"/>
  <text x="590" y="325" fill="#3E5E80" font-size="10" text-anchor="middle">—</text>
  <rect x="645" y="308" width="90" height="28" rx="3" fill="#0c1520" stroke="#14263E" stroke-width="0.5"/>
  <text x="690" y="325" fill="#3E5E80" font-size="10" text-anchor="middle">—</text>
  <rect x="745" y="308" width="90" height="28" rx="3" fill="#0c1520" stroke="#14263E" stroke-width="0.5"/>
  <text x="790" y="325" fill="#3E5E80" font-size="10" text-anchor="middle">—</text>

  <!-- diff row -->
  <rect x="145" y="348" width="90" height="28" rx="3" fill="#082010" stroke="#43A047" stroke-width="0.7"/>
  <text x="190" y="365" fill="#A5D6A7" font-size="11" text-anchor="middle">0.26</text>
  <rect x="245" y="348" width="90" height="28" rx="3" fill="#082010" stroke="#43A047" stroke-width="0.7"/>
  <text x="290" y="365" fill="#A5D6A7" font-size="11" text-anchor="middle">0.27</text>
  <rect x="345" y="348" width="90" height="28" rx="3" fill="#0c1520" stroke="#14263E" stroke-width="0.5"/>
  <text x="390" y="365" fill="#3E5E80" font-size="10" text-anchor="middle">—</text>
  <rect x="445" y="348" width="90" height="28" rx="3" fill="#082010" stroke="#43A047" stroke-width="0.7"/>
  <text x="490" y="365" fill="#A5D6A7" font-size="11" text-anchor="middle">0.04</text>
  <rect x="545" y="348" width="90" height="28" rx="3" fill="#0c1520" stroke="#14263E" stroke-width="0.5"/>
  <text x="590" y="365" fill="#3E5E80" font-size="10" text-anchor="middle">—</text>
  <rect x="645" y="348" width="90" height="28" rx="3" fill="#0c1520" stroke="#14263E" stroke-width="0.5"/>
  <text x="690" y="365" fill="#3E5E80" font-size="10" text-anchor="middle">—</text>
  <rect x="745" y="348" width="90" height="28" rx="3" fill="#0c1520" stroke="#14263E" stroke-width="0.5"/>
  <text x="790" y="365" fill="#3E5E80" font-size="10" text-anchor="middle">—</text>

  <text x="450" y="392" fill="#3E5E80" font-size="10" text-anchor="middle">All values in µm (width, spacing, pitch, enclosure, via width) or µm² (area). Dash = not applicable for that layer/rule pair.</text>
</svg>
```

---

## 7. Metal Direction Preference

Sky130 follows a preferred routing direction alternation:

| Layer | Preferred Direction |
|---|---|
| LI | horizontal |
| M1 | horizontal |
| M2 | vertical |
| M3 | horizontal |
| M4 | vertical |
| M5 | horizontal |

This is encoded in `pdks/sky130.json`:
```json
"metal_direction": ["horizontal", "vertical", "horizontal", "vertical", "horizontal", ...]
```

Alternating directions minimize via count when routing from one horizontal wire to another (M1 → M2 → M1 requires exactly 2 vias). The Spout maze router (`src/router/maze.zig`) uses this preference but does not enforce it strictly.

---

## 8. Cross-Layer Spacing Rules

These rules apply between shapes on different layers (from `pdks/sky130.json` `cross_rules`):

| Layer A | Layer B | Min Spacing | Physical Meaning |
|---|---|---|---|
| poly (66/20) | diff (65/20) | 0.075 µm | Poly to active isolation (off-gate) |
| poly (66/20) | tap (65/44) | 0.055 µm | Poly to body-tap |
| licon (66/44) | diff (65/20) | 0.19 µm | Contact to adjacent active region |
| licon (66/44) | tap (65/44) | 0.055 µm | Contact to body tap |
| licon (66/44) | poly (66/20) | 0.055 µm | Contact to poly edge |
| tap (65/44) | nwell (64/20) | 0.13 µm | Body tap to well edge |
| diff (65/20) | nwell (64/20) | 0.34 µm | Active region to well edge |

---

## 9. References

| File | Purpose |
|---|---|
| `pdks/sky130.json` | Complete rule set for sky130 in Spout |
| `src/core/route_arrays.zig` | Layer index convention documentation |
| `src/router/DRC_RULES.md` | Algorithmic detail for all rule types |
| `src/export/gdsii.zig` | GDSII export — maps route layers to GDS layer numbers |
