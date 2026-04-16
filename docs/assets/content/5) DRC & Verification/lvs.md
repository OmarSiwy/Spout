# Layout vs. Schematic (LVS)

> **Source files:** `python/tools.py`, `python/main.py`, `pdks/sky130.json`

---

## 1. What Is LVS?

Layout vs. Schematic (LVS) is a sign-off verification step that confirms the physical layout (GDS) electrically matches the intended circuit (SPICE netlist/schematic). It answers: **"Does the thing we built match what we designed?"**

LVS extracts a netlist from the layout — identifying devices and nets from their physical geometry — and then performs graph isomorphism to compare that extracted netlist against the reference schematic.

A clean LVS means:
- Every device in the schematic appears in the layout with matching parameters.
- Every net connection in the schematic is correctly wired in the layout.
- No extra devices, missing devices, short circuits, or open circuits exist.

---

## 2. What LVS Compares

| Compared Property | Layout Side | Schematic Side |
|---|---|---|
| **Device types** | Identified from layer geometry (e.g., poly crossing active = MOSFET) | SPICE `.subckt` element type (M, R, C, Q, ...) |
| **Device parameters** | Extracted W, L, number of fingers from geometry | W=, L= parameters in SPICE |
| **Net connectivity** | Wire connectivity (which terminals share a metal net) | Node connections in SPICE |
| **Power/ground** | Connections to VDD/VSS | `.global` declarations |
| **Port names** | Shape labels or pin shapes on pin-layer GDS datatypes | `.subckt` port list |

---

## 3. Spout's LVS Flow

Spout uses **KLayout** as the external LVS engine, invoked via `python/tools.py: run_klayout_lvs`.

### 3.1 Schematic Preparation

Before running LVS, `prepare_lvs_schematic()` maps generic model names to sky130-specific model names:

```python
_SKY130_MODEL_MAP = {
    "nmos_rvt": "sky130_fd_pr__nfet_01v8",
    "pmos_rvt": "sky130_fd_pr__pfet_01v8",
    "nmos_lvt": "sky130_fd_pr__nfet_01v8_lvt",
    "nmos":     "sky130_fd_pr__nfet_01v8",
    "pmos":     "sky130_fd_pr__pfet_01v8",
    "nfet":     "sky130_fd_pr__nfet_01v8",
    "pfet":     "sky130_fd_pr__pfet_01v8",
}
```

SPICE MOSFET lines (`M...`) have their sixth token (model name) remapped. Short aliases `n` and `p` are also recognized.

A `.global vss` directive is prepended if not already present, ensuring the ground net is declared globally.

### 3.2 KLayout LVS Invocation

```bash
klayout -b -r sky130.lylvs
    -rd input={gds_path}
    -rd schematic={mapped_schematic}
    -rd topcell={cell_name}
    -rd report={report_file}
```

The LVS script is located at `$PDK_ROOT/sky130A/libs.tech/klayout/lvs/sky130.lylvs` (or `sky130.lvs`).

### 3.3 Result Parsing

KLayout writes pass/fail information to stdout/stderr. The wrapper looks for:
- `"NETLIST MATCH"` or `"netlists match"` → `{match: True}`
- `"NETLIST MISMATCH"` or `"netlists don't match"` → `{match: False, details: output}`
- Anything else → `{error: "LVS inconclusive"}`

The full pipeline's success condition (`python/main.py`) is:
```python
success = drc_violations == 0 and lvs_clean
```

---

## 4. How KLayout Extracts the Layout Netlist

KLayout's LVS engine (for sky130) uses the PDK-provided Ruby DRC/LVS script. The extraction process:

### 4.1 Device Recognition

KLayout identifies devices by layer combinations:
- **MOSFET:** poly shape overlapping diffusion (active) region
  - NMOS: poly ∩ diff in p-substrate region (no nwell under diff)
  - PMOS: poly ∩ diff inside nwell
- **Resistor:** poly or diffusion segment with specific implant layers
- **Capacitor:** MIM cap (metal-oxide-metal stack on specific layers)

For sky130, the primary device-recognition layers are:
- poly (GDS 66/20) crossing diff (GDS 65/20) → gate region
- nwell (GDS 64/20) region → PMOS candidate
- nsdm (GDS 93/44) implant → N+ source/drain
- psdm (GDS 94/20) implant → P+ source/drain

### 4.2 Net Extraction

Nets are traced by metal connectivity:
1. Start from a pin shape (pin-layer datatype, e.g., GDS 68/5 for M1 pin).
2. Flood-fill through all touching metal shapes on the same layer.
3. Follow vias (contact/via layers) to connected metal on adjacent layers.
4. Continue until all reachable shapes are collected.

### 4.3 Terminal Assignment

Device terminals are assigned to nets by finding which net's geometry overlaps the device's terminal regions:
- Gate terminal: the poly shape that forms the gate
- Source/drain: the diffusion contacts (licon → LI → M1) connecting to the diffusion regions
- Body: the tap (GDS 65/44) contacts connecting to the well/substrate

---

## 5. Device Matching Algorithm

LVS uses **netlist graph isomorphism** to match the extracted layout netlist against the schematic:

```
1. Build layout graph G_L:
   - Nodes: extracted devices + nets
   - Edges: device-terminal → net connections

2. Build schematic graph G_S:
   - Nodes: schematic devices + nets
   - Edges: device-terminal → net connections

3. Find isomorphism f: G_L → G_S such that:
   - f(device) maps to matching device type
   - f(net) maps to matching net
   - Device parameters are within tolerance
   - All connectivity is preserved
```

If no valid isomorphism exists → LVS mismatch.

**Parameter matching tolerance:** W and L must match within a small tolerance (KLayout's LVS script handles this). Spout's GDSII exporter writes device parameters from `DeviceArrays.params` which are sourced directly from the SPICE netlist, so parameters should match exactly.

---

## 6. Common LVS Errors and Their Causes

### 6.1 Missing Device

**Symptom:** Layout has fewer devices than schematic.

**Causes:**
- Device was not placed (placement failure or skipped)
- Device dimensions are too small to be recognized (poly or diff below min width)
- Device was placed outside the cell boundary and cropped on export

**Spout-specific:** Uncommon — the GDSII exporter iterates over all devices in `DeviceArrays` and writes each one.

### 6.2 Extra Device

**Symptom:** Layout has more devices than schematic.

**Causes:**
- Guard rings generate tap contacts that KLayout may count as extra devices
- Dummy devices (`DeviceArrays.is_dummy == true`) were included in export

### 6.3 Net Short

**Symptom:** Two nets that should be separate are connected in the layout.

**Causes:**
- Routing placed a wire that connects two unintended nets (spacing violation causing accidental connection)
- Via enclosure failure caused a via to make contact with the wrong layer
- Guard ring creates an unintended connection

**Detection:** The inline DRC checker prevents same-layer overlaps between different nets, but via layer violations can create shorts that are only detected by LVS.

### 6.4 Net Open

**Symptom:** A net in the layout has fewer connections than the schematic.

**Causes:**
- A via was omitted (via placement failure)
- A pin shape is missing from the GDS output
- A wire segment was removed by repair without reconnection

### 6.5 Parameter Mismatch

**Symptom:** Device found, but W or L doesn't match.

**Causes:**
- `param_to_um` conversion error (sky130 uses 1000000.0 scale factor — SPICE values are in meters, layout in µm)
- `computeDeviceDimensions` applies guard ring extensions that may slightly change the exported geometry vs. the nominal parameters

**sky130 model name mapping:** A critical LVS issue specific to sky130 is model name mismatches. SPICE netlists may use shorthand names (`nmos`, `nfet`, `n`) that KLayout LVS does not recognize. `prepare_lvs_schematic()` handles this by mapping to canonical names like `sky130_fd_pr__nfet_01v8`.

### 6.6 Floating Net

**Symptom:** A net in the layout connects to no device pin.

**Causes:**
- Wire routed to a location that has no device underneath
- Pin shapes not generated on the correct layer/datatype

---

## 7. Spout's Layout Netlist Generation

The layout netlist for LVS comparison comes from two sources:

### 7.1 Device Geometry (GDSII Export)

`src/export/gdsii.zig` writes each device from `DeviceArrays`:
- Poly rectangles (gate)
- Diffusion rectangles with source/drain implants
- Contact arrays (licon)
- LI/M1 connections
- Body tap (tap layer 65/44) with nwell for PMOS

The cell contains explicit pin shapes on `metal_pin` layers (e.g., GDS 68/5 for M1 pins) with text labels matching the schematic port names.

### 7.2 Net Routing (GDSII Export)

`RouteArrays` segments are exported as GDS rectangles on the corresponding metal layers. Each segment:
- `layer 0` → GDS 67/20 (LI)
- `layer 1` → GDS 68/20 (M1)
- `layer 2` → GDS 69/20 (M2)
- etc.

Via segments (zero-length segments in `RouteArrays`) are exported as GDS cut rectangles:
- M1-M2 via → GDS 68/44
- M2-M3 via → GDS 69/44
- etc.

---

## 8. LVS with GDS Template

When a GDS template is loaded (`TemplateConfig` in `main.py`), the hierarchy becomes:
```
top_cell (template wrapper)
  └── user_analog_circuit (routed circuit)
```

KLayout LVS must match against the hierarchical structure. The `top_cell` is passed as `-rd topcell` so KLayout's LVS flattens from that entry point, matching the complete hierarchy against the schematic.

---

## 9. References

| File | Purpose |
|---|---|
| `python/tools.py` | `run_klayout_lvs()`, `prepare_lvs_schematic()` |
| `python/main.py` | Pipeline LVS step (stage 6b) |
| `src/export/gdsii.zig` | GDSII export that produces the layout netlist |
| `pdks/sky130.json` | Layer map for pin shapes and metal layers |
| `src/lib.zig` | `SpoutContext` — top-level context holding device + route data |
