# Parasitic Extraction (PEX)

> **Source files:** `src/router/pex_feedback.zig`, `python/tools.py`, `python/main.py`

---

## 1. What Is PEX?

Parasitic Extraction (PEX) computes the resistances and capacitances that exist in a real physical layout beyond the intended circuit elements. Every wire has:

- **Series resistance** from the metal's sheet resistance.
- **Capacitance to the substrate** (area capacitance from the ground plane below).
- **Coupling capacitance** to adjacent wires on the same or neighboring layers.
- **Via resistance** from contact resistance at each via cut.

These parasitics degrade circuit performance — RC delays cause bandwidth limitations, coupling capacitances cause crosstalk, and via resistance adds offset in matched analog circuits.

---

## 2. Two-Tier PEX in Spout

Spout uses two complementary PEX flows:

| Tier | Location | Method | Role |
|---|---|---|---|
| **In-engine PEX** | `src/router/pex_feedback.zig` (calls `src/characterize/pex.zig`) | Analytic, sheet-resistance model | Drives the PEX feedback loop for analog matching during routing |
| **Signoff PEX** | `python/tools.py: run_magic_pex` | Magic `ext2spice` (SPICE output) | Post-layout sign-off PEX |

---

## 3. In-Engine PEX Algorithm (`pex_feedback.zig`)

### 3.1 Per-Net Extraction (`extractNet`)

```
Input:  RouteArrays (all segments), NetIdx, PexConfig
Output: NetResult { total_r, total_c, via_count, seg_count, length }

Algorithm:
1. Filter RouteArrays to segments belonging to the target net.
2. Call pex_mod.extractFromRoutes() on the filtered segment list.
3. Sum resistors where net_a == net_b (series resistance on the net).
4. Sum capacitors where net_b == SUBSTRATE_NET (capacitance to ground).
5. Count via segments: segments where x1==x2 and y1==y2 (zero-length) are vias.
6. Sum Euclidean length of all non-via segments.
```

Via detection uses the zero-length segment convention: vias in `RouteArrays` are represented as segments with equal start and end coordinates on their layer.

### 3.2 Resistance Model

Wire resistance uses the sheet resistance model:

```
R_segment = R_sheet × (length / width)    [Ohms]
```

`PexConfig.sheet_resistance` is indexed by route layer index:
- Index 0 = LI, 1 = M1, 2 = M2, ..., 5 = M5

`PexConfig.sky130()` provides the default sky130 sheet resistance values (mΩ/sq for each layer).

The `repairWidths` function in `pex_feedback.zig` computes per-net resistance inline from the `PexConfig` to determine which net has higher resistance:

```zig
const seg_r = sheet_r * seg_len / w;   // Ohms for one segment
```

### 3.3 Capacitance Model

`extractFromRoutes` (in `src/characterize/pex.zig`) computes:
1. **Area capacitance** from segment area × area_cap_per_um2 per layer.
2. **Fringe capacitance** from segment perimeter × fringe_cap_per_um per layer.
3. **Coupling capacitance** between adjacent segments on the same layer (within coupling distance).

The in-engine model uses simplified parallel-plate + fringe approximation. For sky130:
- LI to substrate: dominant due to proximity to active/poly
- M1: significant area cap, moderate coupling
- M2+: lower substrate cap (more oxide thickness), higher inter-layer coupling

### 3.4 Match Report Computation (`computeMatchReport`)

For two-net analog-matched groups (e.g., differential pairs):

```
r_ratio    = |R_a - R_b| / max(R_a, R_b)     ∈ [0, 1]
c_ratio    = |C_a - C_b| / max(C_a, C_b)     ∈ [0, 1]
length_ratio = |L_a - L_b| / max(L_a, L_b)   ∈ [0, 1]
via_delta  = via_count_a - via_count_b         ∈ ℤ
coupling_delta = |C_a - C_b|                  [fF]
```

`passes = true` when all metrics ≤ tolerance AND |via_delta| ≤ 1 AND coupling_delta ≤ 0.5 fF.

**Failure priority:** First failing metric sets `failure_reason`. If multiple metrics fail, the first-checked one in order (r, c, length, via_delta, coupling) is reported.

**Repair severity ranking:** The `selectRepairAction` function ranks failures by severity:
```
coupling_mismatch > via_mismatch > r_mismatch > c_mismatch > length_mismatch
```

---

## 4. PEX Feedback Loop

The feedback loop in `runPexFeedbackLoop` iterates up to `MAX_PEX_ITERATIONS = 5` times:

```
while iter < 5:
    1. extractNet(routes, net_a) → result_a
    2. extractNet(routes, net_b) → result_b
    3. computeMatchReport(result_a, result_b, tolerance) → report
    4. if report.passes → break (converged)
    5. repairFromPexReport(report, routes, ...) → mutate RouteArrays
    iter += 1
```

Each iteration directly mutates the `RouteArrays` in-place (widths, layers, extra segments). The repair strategies are:

### 4.1 Width Repair (`repairWidths`)

**When:** `r_mismatch` failure (resistance ratio exceeds tolerance)

**Algorithm:**
1. Compute per-net total resistance using `PexConfig.sheet_resistance`.
2. Determine which net has higher resistance (`wider_id`).
3. Scale the higher-resistance net's segment widths by `target_wider = 1 + (scale-1) × 0.5` (50% correction toward balance).
4. Apply: `routes.width[i] *= target_wider` for all segments of `wider_id`.

**Physical effect:** Wider wires have lower sheet resistance per unit length. Widening the higher-R net's routes reduces its resistance, moving the pair toward balance.

### 4.2 Length Repair (`repairLength`)

**When:** `length_mismatch` failure

**Algorithm:**
1. Compute `deficit = longer_len - shorter_len`.
2. Find the middle segment of the shorter net (by accumulated length ≥ total/2).
3. Insert a perpendicular jog at the midpoint of that segment.
4. Jog length = `min(deficit / 2, 2.0)` µm (capped at 2 µm to prevent excessive area use).
5. Direction: if the segment is horizontal, add a vertical jog; if vertical, add horizontal.

**Physical effect:** Adds wire length to the shorter net to equalize total wire lengths, which equalizes both resistance and inductance.

### 4.3 Dummy Via Repair (`repairVias`)

**When:** `via_mismatch` failure (|via_delta| > 1)

**Algorithm:**
1. Determine which net has fewer vias.
2. Find non-via segments of that net.
3. Insert `|delta| - 1` dummy vias (zero-length segments) at midpoints of those segments.

**Physical effect:** Via resistance in sky130 is a fixed per-via value (contact resistance). Equalizing via counts equalizes via resistance contribution. Dummy vias also improve parasitic symmetry in matching-sensitive analog design.

**Note:** Dummy vias are flagged with `RouteSegmentFlags.is_dummy_via = true` in production code. The `pex_feedback.zig` implementation inserts them as zero-length segments on the same layer (self-via).

### 4.4 Coupling Repair (`repairCoupling`)

**When:** `coupling_mismatch` failure (coupling_delta > 0.5 fF)

**Algorithm:**
1. Find the segment with the lowest layer index across both nets.
2. If that layer is in range [2, 5] (M2–M5), promote all segments of that net to `layer + 1`.

**Physical effect:** Higher metal layers have greater separation from the substrate and from lower-layer wires. Moving the lower net up reduces its coupling capacitance to the other net (which is on the original layer), improving symmetry.

**Constraint:** The function only operates when the lower layer is ≥ 2 (M2) to prevent promoting LI or M1 wires beyond the routing stack.

---

## 5. Signoff PEX — Magic `ext2spice`

The external PEX flow (`python/tools.py: run_magic_pex`) invokes Magic in batch mode:

```tcl
tech load sky130A.tech
gds read {gds_path}
load {top_cell}
select top cell
extract do resistance
extract do capacitance
extract do coupling
extract all
ext2spice hierarchy on
ext2spice format ngspice
ext2spice cthresh 0    ; include all caps regardless of threshold
ext2spice rthresh 0    ; include all resistors regardless of threshold
ext2spice
```

**Output:** A SPICE netlist (`{top_cell}.spice`) containing:
- `R` elements for wire resistance (from `.ext` file `resist` lines and SPICE `R` instances)
- `C` elements for capacitances (area + fringe + coupling)
- Device elements for MOSFETs, resistors, capacitors from the netlist

**Counting:** The Python wrapper counts:
```python
for line in spice_text:
    if line[0] == 'C': num_cap += 1
    elif line[0] == 'R': num_res += 1
```

Plus additional `resist` lines from the `.ext` intermediate file.

---

## 6. PEX Quality Assessment

`python/main.py: _assess_pex` classifies the PEX result quality:

| Condition | Rating |
|---|---|
| `total_res > 500 Ω OR total_cap > 1000 fF` | "broken" |
| `total_res > 200 Ω OR total_cap > 500 fF` | "poor" |
| `total_res > 50 Ω OR total_cap > 100 fF` | "acceptable" |
| `total_res < 15 Ω AND total_cap < 1 fF` | "excellent" |
| Otherwise | "good" |

These thresholds are heuristic guidelines for small analog circuits. Power amplifiers or large digital blocks will have legitimately higher values.

---

## 7. PEX Output Format (SPICE Netlist)

The signoff PEX produces a SPICE netlist with this structure:

```spice
* Extracted from: top_cell
* Magic VLSI Layout Tool (ext2spice)

.subckt top_cell IN OUT VDD VSS
* Device instances
M1 drain1 gate1 source1 body1 sky130_fd_pr__nfet_01v8 W=1u L=0.15u
M2 drain2 gate2 source2 body2 sky130_fd_pr__pfet_01v8 W=2u L=0.15u

* Parasitic resistors (wire resistance)
R_net1_seg0 IN net1_n1 45.3
R_net1_seg1 net1_n1 gate1 22.7

* Parasitic capacitances (to substrate and coupling)
C_net1_sub net1_n1 VSS 12.5f
C_coup_n1_n2 net1_n1 net2_n1 0.8f

.ends top_cell
```

**Element naming conventions:**
- `R_netname_segN`: wire resistance segment N on net "netname"
- `C_netname_sub`: capacitance from net node to substrate (VSS)
- `C_coup_nA_nB`: coupling capacitance between node on net A and node on net B
- Values: resistance in Ohms, capacitance in Farads (Magic outputs raw values; ngspice scale factors like `f` for femto may be used)

---

## 8. Body-Net and Substrate Modeling

The in-engine PEX identifies substrate connections using `SUBSTRATE_NET` (a special constant in `characterize/types.zig`). During extraction:

1. Capacitors where `net_b == SUBSTRATE_NET` are counted as substrate capacitances.
2. Body connections (VNB for NMOS, VPB for PMOS in sky130) are classified as `PortRole.pwell` / `PortRole.nwell` by `liberty/pdk.zig`.
3. For substrate cap computation, the routing layer's distance from the substrate determines the oxide thickness and therefore the capacitance density.

The `pex_feedback.zig` coupling_delta currently uses a simplified approximation:
```zig
const coupling_delta = @abs(net_a.total_c - net_b.total_c);  // fF — C difference as proxy
```
This treats the total substrate capacitance difference as a proxy for coupling asymmetry. A more accurate implementation would separately track inter-net coupling caps.

---

## 9. Known Limitations and Approximations

| Limitation | Impact | Future Work |
|---|---|---|
| Coupling_delta uses total_c difference as proxy | May miss coupling between two nets that both have high substrate C | Track inter-net Cc separately in RcElement |
| Width repair applies 50% correction factor | May not converge in 1 iteration | Adaptive correction factor based on ratio |
| Jog repair capped at 2 µm | Cannot compensate large length mismatches | Multi-jog insertion |
| Coupling repair only promotes full layer | Coarse — may cause DRC violations on the promoted layer | Partial segment promotion |
| Signoff PEX requires Magic installed with sky130A tech | External dependency | May use KLayout PEX (v0.30+) as alternative |
| `cthresh 0` in Magic ext2spice | Extracts all capacitances regardless of value, including negligible ones | Production runs may want `cthresh 0.1f` to reduce netlist size |

---

## 10. Cross-Section: Parasitic Elements in Layout

```svg
<svg viewBox="0 0 900 520" xmlns="http://www.w3.org/2000/svg" font-family="'Inter','Segoe UI',sans-serif">
  <!-- Background -->
  <rect width="900" height="520" fill="#060C18"/>
  <text x="450" y="30" fill="#B8D0E8" font-size="18" font-weight="bold" text-anchor="middle">Parasitic Elements — Layer Cross-Section</text>

  <!-- ── Substrate ── -->
  <rect x="40" y="440" width="820" height="50" rx="4" fill="#2a1a00" stroke="#FB8C00" stroke-width="1"/>
  <text x="450" y="470" fill="#FB8C00" font-size="13" text-anchor="middle">Silicon Substrate (p-type bulk)</text>

  <!-- ── Oxide / ILD layers (light bands) ── -->
  <rect x="40" y="390" width="820" height="48" rx="0" fill="#0a1820" stroke="#14263E"/>
  <text x="60" y="420" fill="#3E5E80" font-size="10">ILD1 (SiO₂ interlayer dielectric — M1 to substrate)</text>

  <rect x="40" y="310" width="820" height="78" rx="0" fill="#0a1820" stroke="#14263E"/>
  <text x="60" y="355" fill="#3E5E80" font-size="10">ILD2 (M2 to M1 dielectric)</text>

  <rect x="40" y="220" width="820" height="88" rx="0" fill="#0a1820" stroke="#14263E"/>
  <text x="60" y="268" fill="#3E5E80" font-size="10">ILD3 (M3 to M2 dielectric)</text>

  <!-- ── M1 wires ── -->
  <!-- Wire 1 (left) -->
  <rect x="100" y="360" width="140" height="28" rx="3" fill="#1E88E5" fill-opacity="0.85" stroke="#1E88E5" stroke-width="1.5"/>
  <text x="170" y="378" fill="#fff" font-size="11" text-anchor="middle" font-weight="bold">M1 Wire A</text>

  <!-- Wire 2 (right, same layer) -->
  <rect x="320" y="360" width="140" height="28" rx="3" fill="#1E88E5" fill-opacity="0.85" stroke="#1E88E5" stroke-width="1.5"/>
  <text x="390" y="378" fill="#fff" font-size="11" text-anchor="middle" font-weight="bold">M1 Wire B</text>

  <!-- ── Coupling cap between M1 wires ── -->
  <line x1="242" y1="374" x2="318" y2="374" stroke="#00C4E8" stroke-width="2" stroke-dasharray="5,3"/>
  <!-- Capacitor symbol -->
  <line x1="272" y1="367" x2="272" y2="381" stroke="#00C4E8" stroke-width="2"/>
  <line x1="288" y1="367" x2="288" y2="381" stroke="#00C4E8" stroke-width="2"/>
  <text x="280" y="357" fill="#00C4E8" font-size="12" font-weight="bold" text-anchor="middle">Cc</text>
  <text x="280" y="398" fill="#00C4E8" font-size="10" text-anchor="middle">coupling cap</text>

  <!-- ── Area cap: Wire A to substrate ── -->
  <line x1="170" y1="390" x2="170" y2="438" stroke="#00C4E8" stroke-width="2" stroke-dasharray="4,3"/>
  <!-- Cap symbol -->
  <line x1="155" y1="420" x2="185" y2="420" stroke="#00C4E8" stroke-width="2"/>
  <line x1="155" y1="430" x2="185" y2="430" stroke="#00C4E8" stroke-width="2"/>
  <text x="200" y="426" fill="#00C4E8" font-size="12" font-weight="bold">Ca</text>
  <text x="200" y="440" fill="#00C4E8" font-size="10">area cap to substrate</text>

  <!-- ── Via between M1 and M2 ── -->
  <rect x="500" y="350" width="22" height="40" rx="2" fill="#FB8C00" fill-opacity="0.9" stroke="#FB8C00" stroke-width="1.5"/>
  <text x="511" y="344" fill="#FB8C00" font-size="10" text-anchor="middle">via</text>

  <!-- Via resistance symbol -->
  <!-- Zigzag resistor -->
  <polyline points="511,305 511,310 504,316 518,323 504,330 518,337 511,343" fill="none" stroke="#00C4E8" stroke-width="2"/>
  <text x="535" y="325" fill="#00C4E8" font-size="12" font-weight="bold">Rv</text>
  <text x="535" y="339" fill="#00C4E8" font-size="10">via resistance</text>

  <!-- ── M2 wire above via ── -->
  <rect x="420" y="280" width="180" height="28" rx="3" fill="#AB47BC" fill-opacity="0.85" stroke="#AB47BC" stroke-width="1.5"/>
  <text x="510" y="298" fill="#fff" font-size="11" text-anchor="middle" font-weight="bold">M2 Wire C</text>

  <!-- ── Wire resistance symbol on M1 Wire A ── -->
  <!-- Zigzag on top of wire A -->
  <polyline points="100,348 107,341 114,348 121,341 128,348 135,341 142,348" fill="none" stroke="#00C4E8" stroke-width="1.5"/>
  <text x="120" y="333" fill="#00C4E8" font-size="12" font-weight="bold" text-anchor="middle">Rw</text>
  <text x="120" y="322" fill="#00C4E8" font-size="10" text-anchor="middle">wire resistance</text>

  <!-- ── M2 area cap ── -->
  <line x1="510" y1="308" x2="510" y2="358" stroke="#00C4E8" stroke-width="1.5" stroke-dasharray="3,3"/>

  <!-- ── Legend box ── -->
  <rect x="620" y="360" width="240" height="130" rx="6" fill="#09111F" stroke="#14263E"/>
  <text x="740" y="382" fill="#B8D0E8" font-size="13" font-weight="bold" text-anchor="middle">Legend</text>
  <line x1="640" y1="400" x2="670" y2="400" stroke="#00C4E8" stroke-width="2" stroke-dasharray="5,3"/>
  <text x="680" y="404" fill="#B8D0E8" font-size="11">Cc — coupling capacitance</text>
  <line x1="640" y1="420" x2="670" y2="420" stroke="#00C4E8" stroke-width="2" stroke-dasharray="4,3"/>
  <text x="680" y="424" fill="#B8D0E8" font-size="11">Ca — area cap to substrate</text>
  <polyline points="640,434 645,440 655,434 660,440" fill="none" stroke="#00C4E8" stroke-width="2"/>
  <text x="680" y="443" fill="#B8D0E8" font-size="11">Rv — via resistance</text>
  <polyline points="640,454 645,460 655,454 660,460" fill="none" stroke="#00C4E8" stroke-width="2"/>
  <text x="680" y="463" fill="#B8D0E8" font-size="11">Rw — wire resistance</text>

  <!-- ── Layer labels ── -->
  <text x="862" y="298" fill="#AB47BC" font-size="11" font-weight="bold">M2</text>
  <text x="862" y="376" fill="#1E88E5" font-size="11" font-weight="bold">M1</text>
  <text x="862" y="465" fill="#FB8C00" font-size="11" font-weight="bold">sub</text>

  <!-- ── Fringe cap label ── -->
  <text x="390" y="450" fill="#3E5E80" font-size="10" text-anchor="middle">Fringe cap: from wire sidewalls — also adds to Ca</text>

  <!-- Title arrow annotations -->
  <text x="450" y="510" fill="#3E5E80" font-size="10" text-anchor="middle">Extracted by Magic ext2spice (signoff) or Spout in-engine PEX (routing feedback). Both produce R and C netlist elements.</text>
</svg>
```

---

## 11. References

| File | Purpose |
|---|---|
| `src/router/pex_feedback.zig` | PEX feedback loop, match reports, repair actions |
| `src/characterize/pex.zig` | Core extraction engine (called by pex_feedback) |
| `src/characterize/types.zig` | `RcElement`, `PexResult`, `PexConfig`, `SUBSTRATE_NET` |
| `python/tools.py` | `run_magic_pex()` — Magic ext2spice wrapper |
| `python/main.py` | `_assess_pex()` — quality classification |
| `pdks/sky130.json` | Layer sheet resistance values (via `PexConfig.sky130()`) |
