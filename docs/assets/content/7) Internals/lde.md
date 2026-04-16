# Local Density Effects (LDE)

> **Source file:** `src/router/lde.zig`

---

## 1. What Are Local Density Effects?

In sub-micron CMOS processes, a MOSFET's electrical characteristics depend not only on its own geometry (W, L) but also on the physical environment of the surrounding layout. This family of effects is called **Layout Dependent Effects** (LDE) — sometimes also called layout-dependent variability.

The primary LDE mechanisms in sky130 and similar processes are:

### 1.1 Stress Effects (STI Stress)

Shallow Trench Isolation (STI) fills the space between active regions with silicon dioxide, which has a different thermal expansion coefficient from silicon. During thermal processing, the STI exerts mechanical stress on nearby transistors.

- **Compressive stress (PMOS benefit):** Stress along the channel for PMOS increases hole mobility → higher current.
- **Tensile stress (NMOS benefit):** Tensile stress for NMOS increases electron mobility.
- **SA and SB:** The stress magnitude depends on the distance from the active region's edge to the nearest STI boundary:
  - **SA (Source-to-Active edge)** = distance from the source junction to the nearest STI edge on the source side
  - **SB (Body-to-Active edge)** = distance from the gate to the nearest STI edge on the body/drain side

Transistors with large SA/SB have less STI-induced stress → different threshold voltage (Vth) and drive current compared to transistors with small SA/SB.

### 1.2 Well Proximity Effect (WPE)

During ion implantation for well formation (e.g., the n-well implant for PMOS), ions scatter from the photoresist edge. Transistors near the well edge receive a different dose of well dopant, shifting Vth.

- **SCA (Active-to-Well-edge distance)** = distance from the transistor's active region to the nearest well boundary
- Large SCA → transistor is far from the well edge → less WPE → closer to nominal Vth
- Small SCA → transistor is near the well edge → more WPE → Vth shift

### 1.3 Why LDE Matters for Analog Design

In analog circuits, matched transistors (differential pairs, current mirrors) must have identical characteristics. If two "identical" transistors have different SA, SB, or SCA values because of their placement in the layout, they will have measurable Vth and current mismatches even if their W and L are the same.

The matching error from LDE can exceed the intrinsic random mismatch (Pelgrom's law) at small W/L ratios, making LDE the dominant mismatch mechanism in modern analog design.

---

## 2. Spout's LDE Model

Spout models LDE through the `LDEConstraintDB` in `src/router/lde.zig`. The database specifies, for each device that requires LDE-controlled placement:

| Parameter | Meaning |
|---|---|
| `min_sa` | Minimum required SA spacing (µm) |
| `max_sa` | Maximum allowed SA spacing (µm) |
| `min_sb` | Minimum required SB spacing (µm) |
| `max_sb` | Maximum allowed SB spacing (µm) |
| `sc_target` | Target SCA for WPE compensation (µm, 0 = no WPE constraint) |

**Constraints define a window of acceptable SA/SB values** — not just a minimum. If SA is too large, the transistor's stress environment differs from the matched device's stress environment; if SA is too small, it may violate DRC rules.

---

## 3. Keepout Generation

The `LDEConstraintDB` generates two types of routing keepout rectangles:

### 3.1 SA/SB Keepouts (`generateKeepouts`)

For each constrained device:
1. Get the device's bounding box from `device_bboxes[dev.toInt()]`.
2. Expand the bounding box **asymmetrically** based on device type:
   - **NMOS:** expand left by `min_sa`, expand right by `min_sb`
     (NMOS: source is on the left side, body is on the right)
   - **PMOS:** expand left by `min_sb`, expand right by `min_sa`
     (PMOS: source is on the right side, body is on the left)
   - **Other:** expand all sides by `max(min_sa, min_sb)` (conservative symmetric)
3. Return the expanded rectangle as a routing keepout.

**Purpose:** Routing a wire through the SA/SB region of a transistor would alter the active-edge spacing, changing the stress experienced by the device. The keepout prevents the router from placing wires inside this critical region.

```zig
const keepout = switch (dev_type) {
    .nmos => bbox.expandAsymmetric(sa, sb, 0, 0),  // left=SA, right=SB
    .pmos => bbox.expandAsymmetric(sb, sa, 0, 0),  // left=SB, right=SA
    else  => bbox.expand(@max(sa, sb)),
};
```

### 3.2 WPE Keepouts (`generateWPEKeepouts`)

For each device with `sc_target > 0`:
1. Get the device bounding box.
2. Expand the well-facing side by `sc_target`:
   - **NMOS:** expand top (y2) by `sc_target` — nwell edge is typically above NMOS
   - **PMOS:** expand bottom (y1) by `sc_target` — PMOS is inside nwell, substrate below
3. Return as a WPE exclusion zone.

```zig
const wpe_zone = switch (dev_type) {
    .nmos => bbox.expandAsymmetric(0, 0, 0, sc),  // top = well side
    .pmos => bbox.expandAsymmetric(0, 0, sc, 0),  // bottom = well side
    else  => continue,  // skip non-MOSFET devices
};
```

**Purpose:** Routing wires or placing structures near a transistor's well boundary can change the effective `sc_target` distance, altering the WPE dose and shifting Vth.

---

## 4. A\* Cost Function Integration

The LDE cost function penalizes routing decisions that create asymmetric SA/SB environments between matched devices.

### 4.1 Basic LDE Cost

```zig
pub fn computeLDECost(sa_a: f32, sb_a: f32, sa_b: f32, sb_b: f32) f32 {
    return @abs(sa_a - sa_b) + @abs(sb_a - sb_b);
}
```

Returns the total SA+SB asymmetry between two devices. A\* adds this to the path cost when the candidate route would alter the SA or SB of either device.

**A symmetric pair** (sa_a == sa_b, sb_a == sb_b) has zero LDE cost.

### 4.2 Tolerance-Gated LDE Cost

```zig
pub fn computeLDECostScaled(sa_a, sb_a, sa_b, sb_b, tolerance) f32 {
    const sa_penalty = if (@abs(sa_a - sa_b) > tolerance)
        @abs(sa_a - sa_b) - tolerance else 0;
    const sb_penalty = if (@abs(sb_a - sb_b) > tolerance)
        @abs(sb_a - sb_b) - tolerance else 0;
    return sa_penalty + sb_penalty;
}
```

Only penalizes SA/SB differences that exceed `tolerance`. This prevents excessive penalization for small, unavoidable geometric differences while strongly penalizing large asymmetries.

**Example:** With tolerance = 0.1 µm:
- SA difference of 0.05 µm → 0 penalty (within tolerance)
- SA difference of 0.5 µm → 0.4 µm penalty
- SB difference of 0.5 µm → 0.4 µm penalty
- Total: 0.8 µm cost

---

## 5. Integration with the Router

The LDE system integrates into the analog router's A\* expansion loop:

```
For each candidate expansion point P:
    1. Find all devices whose SA/SB region overlaps with P
       (using LDEConstraintDB.findByDevice and device bboxes)
    2. For each pair of matched devices that P affects:
       computeLDECostScaled(sa_a, sb_a, sa_b, sb_b, tolerance)
       → add to candidate's path cost
    3. Check if P is inside any keepout from generateKeepouts
       → if yes, reject candidate
    4. Check if P is inside any WPE keepout from generateWPEKeepouts
       → if yes, reject or heavily penalize
```

Keepout zones produce hard rejections; LDE cost produces soft penalties that guide the router toward symmetric paths without completely blocking certain regions.

---

## 6. SA/SB Measurement

SA and SB are measured in the layout as:
- **SA** = distance from the gate edge (on the source side) to the edge of the nearest diffusion region on a different net, or to the field oxide edge.
- **SB** = same, on the body/drain side.

In Spout's model, the device's bounding box represents the physical extent of the active region. The keepout zone represents the region where other active shapes must not be placed to maintain the target SA/SB. Routing wires do not directly set SA/SB (metal wires don't affect STI stress), but the keepouts also prevent metal from being routed in a way that would require realigning the active regions during layout editing.

**Indirect SA/SB influence:** In a complete layout, other devices placed within the SA/SB zone would reduce the effective spacing. The router keepout prevents this by blocking the zone. In the final layout, if no active region appears within the keepout zone, the SA/SB target is met.

---

## 7. Analog Group Types and LDE Relevance

From `pex_feedback.zig`:

```zig
pub const AnalogGroupType = enum(u8) {
    differential = 0,   // Differential pair — SA/SB must be symmetric
    matched = 1,        // Current mirror — SA/SB and WPE must match
    shielded = 2,       // Shielded routing — LDE less critical
    kelvin = 3,         // Kelvin connection — focus on resistance, not LDE
    resistor = 4,       // Matched resistor — LDE less critical
    capacitor = 5,      // Matched capacitor — LDE less critical
};
```

LDE constraints are most critical for `differential` and `matched` groups. The `selectRepairAction` heuristic in `pex_feedback.zig` does not currently dispatch to LDE repair (it focuses on R, C, length, via, and coupling mismatches), but LDE asymmetry is a root cause of current mismatch that manifests as R and C differences in the PEX loop.

---

## 8. LDE SVG Diagram

```svg
<svg viewBox="0 0 900 520" xmlns="http://www.w3.org/2000/svg" font-family="'Inter','Segoe UI',sans-serif">
  <rect width="900" height="520" fill="#060C18"/>
  <text x="450" y="28" fill="#B8D0E8" font-size="17" font-weight="bold" text-anchor="middle">Layout Dependent Effects (LDE) — SA, SB, SCA Visualization</text>

  <!-- STI field (entire chip surface) -->
  <rect x="30" y="60" width="840" height="420" rx="4" fill="#0a1020" stroke="#14263E" stroke-width="1"/>
  <text x="450" y="80" fill="#3E5E80" font-size="11" text-anchor="middle">STI (Shallow Trench Isolation) — silicon dioxide fill</text>

  <!-- ── NMOS device A (left) ── -->
  <!-- SA keepout (left of device) -->
  <rect x="80" y="120" width="80" height="220" rx="3" fill="#EF5350" fill-opacity="0.08" stroke="#EF5350" stroke-width="1" stroke-dasharray="6,3"/>
  <text x="120" y="114" fill="#EF5350" font-size="9" text-anchor="middle">SA keepout</text>

  <!-- SB keepout (right of device) -->
  <rect x="270" y="120" width="60" height="220" rx="3" fill="#1E88E5" fill-opacity="0.08" stroke="#1E88E5" stroke-width="1" stroke-dasharray="6,3"/>
  <text x="300" y="114" fill="#1E88E5" font-size="9" text-anchor="middle">SB keepout</text>

  <!-- Device A active region -->
  <rect x="162" y="140" width="106" height="180" rx="3" fill="#43A047" fill-opacity="0.7" stroke="#43A047" stroke-width="2"/>
  <text x="215" y="235" fill="#fff" font-size="12" font-weight="bold" text-anchor="middle">NMOS A</text>
  <text x="215" y="252" fill="#fff" font-size="9" text-anchor="middle">W=2µm L=0.15µm</text>

  <!-- Poly gate A -->
  <rect x="200" y="120" width="28" height="220" rx="2" fill="#EF5350" fill-opacity="0.8" stroke="#EF5350" stroke-width="1.5"/>
  <text x="214" y="115" fill="#EF5350" font-size="9" text-anchor="middle">poly</text>

  <!-- SA arrow (left side, source to STI) -->
  <line x1="80" y1="230" x2="160" y2="230" stroke="#00C4E8" stroke-width="2" marker-end="url(#la)" marker-start="url(#lal)"/>
  <text x="120" y="222" fill="#00C4E8" font-size="11" font-weight="bold" text-anchor="middle">SA</text>
  <text x="120" y="244" fill="#00C4E8" font-size="9" text-anchor="middle">1.5µm</text>

  <!-- SB arrow (right side, body to next device) -->
  <line x1="270" y1="230" x2="330" y2="230" stroke="#00C4E8" stroke-width="2" marker-end="url(#la)" marker-start="url(#lal)"/>
  <text x="300" y="222" fill="#00C4E8" font-size="11" font-weight="bold" text-anchor="middle">SB</text>
  <text x="300" y="244" fill="#00C4E8" font-size="9" text-anchor="middle">1.5µm</text>

  <!-- ── NMOS device B (right) — matched pair ── -->
  <!-- SA keepout B -->
  <rect x="520" y="120" width="80" height="220" rx="3" fill="#EF5350" fill-opacity="0.08" stroke="#EF5350" stroke-width="1" stroke-dasharray="6,3"/>
  <!-- SB keepout B -->
  <rect x="710" y="120" width="60" height="220" rx="3" fill="#1E88E5" fill-opacity="0.08" stroke="#1E88E5" stroke-width="1" stroke-dasharray="6,3"/>

  <!-- Device B active region -->
  <rect x="602" y="140" width="106" height="180" rx="3" fill="#43A047" fill-opacity="0.7" stroke="#43A047" stroke-width="2"/>
  <text x="655" y="235" fill="#fff" font-size="12" font-weight="bold" text-anchor="middle">NMOS B</text>
  <text x="655" y="252" fill="#fff" font-size="9" text-anchor="middle">W=2µm L=0.15µm</text>

  <!-- Poly gate B -->
  <rect x="640" y="120" width="28" height="220" rx="2" fill="#EF5350" fill-opacity="0.8" stroke="#EF5350" stroke-width="1.5"/>

  <!-- SA arrow B -->
  <line x1="520" y1="230" x2="600" y2="230" stroke="#00C4E8" stroke-width="2" marker-end="url(#la)" marker-start="url(#lal)"/>
  <text x="560" y="222" fill="#00C4E8" font-size="11" font-weight="bold" text-anchor="middle">SA</text>
  <text x="560" y="244" fill="#00C4E8" font-size="9" text-anchor="middle">1.5µm</text>

  <!-- SB arrow B -->
  <line x1="710" y1="230" x2="770" y2="230" stroke="#00C4E8" stroke-width="2" marker-end="url(#la)" marker-start="url(#lal)"/>
  <text x="740" y="222" fill="#00C4E8" font-size="11" font-weight="bold" text-anchor="middle">SB</text>
  <text x="740" y="244" fill="#00C4E8" font-size="9" text-anchor="middle">1.5µm</text>

  <!-- Symmetry indicator -->
  <line x1="215" y1="88" x2="655" y2="88" stroke="#43A047" stroke-width="1.5" stroke-dasharray="8,4"/>
  <text x="435" y="85" fill="#43A047" font-size="10" text-anchor="middle">matched: SA_A == SA_B, SB_A == SB_B → zero LDE cost</text>

  <!-- ── WPE section (below) ── -->
  <!-- nwell region (above NMOS) -->
  <rect x="120" y="370" width="240" height="60" rx="4" fill="#FF6B9D" fill-opacity="0.15" stroke="#FF6B9D" stroke-width="1.5" stroke-dasharray="6,3"/>
  <text x="240" y="395" fill="#FF6B9D" font-size="10" text-anchor="middle">nwell edge (for nearby PMOS or well tap)</text>

  <!-- WPE SCA arrow -->
  <line x1="215" y1="322" x2="215" y2="368" stroke="#00C4E8" stroke-width="2" marker-end="url(#la)" marker-start="url(#lal)"/>
  <text x="248" y="348" fill="#00C4E8" font-size="11" font-weight="bold">SCA</text>
  <text x="248" y="362" fill="#00C4E8" font-size="9">active-to-well distance</text>

  <!-- WPE keepout zone -->
  <rect x="120" y="322" width="240" height="46" rx="3" fill="#AB47BC" fill-opacity="0.08" stroke="#AB47BC" stroke-width="1" stroke-dasharray="5,3"/>
  <text x="240" y="348" fill="#AB47BC" font-size="9" text-anchor="middle">WPE keepout (sc_target)</text>

  <!-- Rogue wire (red — violates keepout) -->
  <line x1="60" y1="270" x2="450" y2="270" stroke="#EF5350" stroke-width="3"/>
  <text x="250" y="262" fill="#EF5350" font-size="10" text-anchor="middle">BLOCKED: wire through SA/SB zone → violates LDE keepout</text>

  <!-- Compliant wire (green — routed around) -->
  <path d="M 60 290 L 140 290 L 140 440 L 820 440 L 820 290 L 780 290" fill="none" stroke="#43A047" stroke-width="2.5"/>
  <text x="440" y="460" fill="#43A047" font-size="10" text-anchor="middle">ALLOWED: wire routes around keepout zone</text>

  <!-- Cost function box -->
  <rect x="320" y="170" width="260" height="120" rx="6" fill="#09111F" stroke="#14263E"/>
  <text x="450" y="190" fill="#B8D0E8" font-size="12" font-weight="bold" text-anchor="middle">LDE Cost Function</text>
  <text x="330" y="210" fill="#B8D0E8" font-size="10" font-family="monospace">cost = |SA_a - SA_b| + |SB_a - SB_b|</text>
  <text x="330" y="228" fill="#3E5E80" font-size="10">Symmetric pair: cost = 0</text>
  <text x="330" y="244" fill="#3E5E80" font-size="10">SA_a=1.5, SA_b=0.5: cost = 1.0µm</text>
  <text x="330" y="260" fill="#3E5E80" font-size="10">Tolerance-gated: only penalizes</text>
  <text x="330" y="274" fill="#3E5E80" font-size="10">diff &gt; tolerance (e.g., 0.1µm)</text>

  <defs>
    <marker id="la" markerWidth="6" markerHeight="5" refX="5" refY="2.5" orient="auto">
      <path d="M0,0 L6,2.5 L0,5 Z" fill="#00C4E8"/>
    </marker>
    <marker id="lal" markerWidth="6" markerHeight="5" refX="1" refY="2.5" orient="auto-start-reverse">
      <path d="M0,0 L6,2.5 L0,5 Z" fill="#00C4E8"/>
    </marker>
  </defs>
</svg>
```

---

## 9. Current Status and Limitations

| Feature | Status | Notes |
|---|---|---|
| `LDEConstraintDB` data structure | Implemented | Full SoA, findByDevice, add/get |
| `generateKeepouts` | Implemented | Tested for NMOS, PMOS, and generic devices |
| `generateWPEKeepouts` | Implemented | Tested, skips zero sc_target |
| `computeLDECost` / `computeLDECostScaled` | Implemented | Used in A\* cost calculation |
| A\* integration | Partial | Cost computed; keepout enforcement depends on router using the keepout list |
| SA/SB parameter extraction from SPICE | Not implemented | Currently, SA/SB must be provided externally or estimated from device pitch |
| Automatic SA/SB from placement | Not implemented | Would require measuring distances after each SA perturbation |
| Multi-finger device SA/SB | Not implemented | Each finger has independent SA/SB; array devices share the outer-edge distances |

---

## 10. References

| File | Purpose |
|---|---|
| `src/router/lde.zig` | Complete LDE implementation: DB, keepouts, cost functions |
| `src/router/pex_feedback.zig` | `AnalogGroupType` enum, group-level matching context |
| `src/core/types.zig` | `DeviceType`, `DeviceIdx` |
| `src/placer/sa.zig` | SA placer — uses LDE cost as one term in the multi-objective cost |
