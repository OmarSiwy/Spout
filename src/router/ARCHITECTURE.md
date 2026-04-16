# Analog-Aware Zero-DRC Router Architecture

## Goal

```
Zero DRC violations.
LVS-correct netlist.
PEX-optimized layout.
Matched parasitics for analog circuits.
```

---

## Executive Summary

OpenROAD's TritonRoute supports zero-DRC routing via embedded constraints (ARCHITECTURE_ZERO_DRC_ROUTER.md). However, it is **digitally-centric** — no support for analog requirements: parasitic symmetry, wire-length matching, thermal awareness, STI stress avoidance, common-centroid routing, guard rings, shielding, or Kelvin connections.

This document describes a hybrid architecture: **OpenROAD for global routing guides + custom analog router in Spout for critical matched nets + iterative PEX feedback loop**.

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                    ANALOG-AWARE ZERO-DRC ROUTER                              │
└─────────────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────────────┐
│  STAGE 1: OpenROAD Global Router (FastRoute) — UNCHANGED                   │
│  Produces routing guides, handles congestion                                  │
│  - Global route → Steiner trees → guides                                     │
└────────────────────────────────┬────────────────────────────────────────────┘
                                 │ guides
                                 ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│  STAGE 2: Spout Analog Router (NEW)                                        │
│  Routes critical matched nets with analog awareness                           │
│                                                                              │
│  ┌──────────────────────────────────────────────────────────────────────┐ │
│  │  AnalogNetGroup database                                                │ │
│  │  - Differential pairs (net_p, net_n)                                   │ │
│  │  - Matched nets (with tolerance)                                       │ │
│  │  - Shielded nets (with ground reference)                               │ │
│  │  - Kelvin nets (sense/force separation)                                 │ │
│  └──────────────────────────────────────────────────────────────────────┘ │
│                                                                              │
│  ┌──────────────────────────────────────────────────────────────────────┐ │
│  │  MatchedRouter                                                         │ │
│  │  - Symmetric Steiner tree generation                                    │ │
│  │  - Wire-length matching (target = shorter net)                         │ │
│  │  - Same metal layer assignment                                         │ │
│  │  - Via count balancing                                                 │ │
│  │  - Parasitic symmetry cost function                                    │ │
│  └──────────────────────────────────────────────────────────────────────┘ │
│                                                                              │
│  ┌──────────────────────────────────────────────────────────────────────┐ │
│  │  ShieldRouter                                                         │ │
│  │  - Ground shield wires on adjacent layers                             │ │
│  │  - Shield between sensitive net and aggressors                         │ │
│  └──────────────────────────────────────────────────────────────────────┘ │
│                                                                              │
│  ┌──────────────────────────────────────────────────────────────────────┐ │
│  │  GuardRingInserter                                                    │ │
│  │  - P+ guard rings around analog blocks (VSS)                          │ │
│  │  - N+ guard rings in N-well (VDD)                                    │ │
│  │  - Deep N-well for analog-digital isolation                            │ │
│  └──────────────────────────────────────────────────────────────────────┘ │
└────────────────────────────────┬────────────────────────────────────────────┘
                                 │ analog-routed guides
                                 ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│  STAGE 3: OpenROAD Detailed Router (FlexDR) — WITH EMBEDDED DRC             │
│  Routes remaining nets with zero-DRC guarantee                               │
│  - Embedded DRC constraints in maze expansion                                 │
│  - DRC violations = hard reject, never enters illegal space                 │
└────────────────────────────────┬────────────────────────────────────────────┘
                                 │ routed geometry
                                 ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│  STAGE 4: RCX + Match Analysis (OpenRCX + Spout)                           │
│                                                                              │
│  extract_parasitics                                                          │
│      ↓                                                                      │
│  analyzeMatching() — compare R, C, length, via_count for matched groups     │
│      ↓                                                                      │
│  if mismatch > tolerance:                                                  │
│      repairGuides() — adjust for next iteration                              │
│      goto STAGE 3                                                           │
│  else:                                                                      │
│      continue                                                               │
└────────────────────────────────┬────────────────────────────────────────────┘
                                 │ verified clean
                                 ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│  STAGE 5: KLayout/Magic Signoff DRC + LVS                                  │
│  Final verification (as currently done in Spout)                            │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## Part I: Mathematical Foundations

### The Pelgrom Mismatch Model

Every layout technique in this router exists to combat one or more components of device mismatch. The Pelgrom model (Pelgrom et al., IEEE JSSC 1989) is the quantitative foundation.

#### Core Equations

For two closely spaced, identically designed transistors:

$$\sigma(\Delta V_T) = \frac{A_{VT}}{\sqrt{W \cdot L}}$$

$$\sigma\!\left(\frac{\Delta \beta}{\beta}\right) = \frac{A_\beta}{\sqrt{W \cdot L}}$$

The full model including distance-dependent systematic terms:

$$\sigma^2(\Delta V_T) = \frac{A_{VT}^2}{W \cdot L} + S_{VT}^2 \cdot D^2$$

where $A_{VT}$ is the Pelgrom coefficient (mV·µm), $W$ and $L$ are gate dimensions (µm), $S_{VT}$ is the spatial gradient coefficient (mV/µm), and $D$ is inter-device distance (µm).

#### Drain Current Mismatch

Starting from the square-law model in saturation, $I_D = \frac{\beta}{2}(V_{GS} - V_T)^2$:

$$\frac{\Delta I_D}{I_D} = \frac{\Delta \beta}{\beta} - \frac{g_m}{I_D} \Delta V_T$$

Since $V_T$ and $\beta$ mismatches are uncorrelated:

$$\sigma^2\!\left(\frac{\Delta I_D}{I_D}\right) = \frac{A_\beta^2}{WL} + \left(\frac{g_m}{I_D}\right)^2 \cdot \frac{A_{VT}^2}{WL}$$

In strong inversion where $g_m/I_D = 2/(V_{GS} - V_T)$:

$$\sigma^2\!\left(\frac{\Delta I_D}{I_D}\right) = \frac{1}{WL}\left[A_\beta^2 + \frac{4 A_{VT}^2}{(V_{GS} - V_T)^2}\right]$$

**Design insight:** Differential pairs benefit from low overdrive (large $g_m/I_D$) where $V_T$ mismatch dominates. Current mirrors benefit from high overdrive where $\beta$ mismatch dominates.

#### Pelgrom Coefficients Across Technology Nodes

| Process node | $A_{VT}$ NMOS (mV·µm) | $A_{VT}$ PMOS (mV·µm) | $A_\beta$ (%·µm) |
| ------------ | --------------------- | --------------------- | ---------------- |
| 500 nm       | 15–20                 | 20–30                 | ~2.0             |
| 180 nm       | ~5                    | 7–8                   | 1–2              |
| 130 nm       | ~3.5                  | ~3.5                  | 1.5–2            |
| 65 nm        | 2.5–3.5               | 3.5–4.5               | ~1.5             |
| 28 nm        | 1.5–2.5               | 2–3                   | 1–1.5            |
| 14 nm FinFET | 1.0–1.5               | —                     | —                |

PMOS typically exhibits $A_{VT} \approx 1.5 \times A_{VT,\text{NMOS}}$. The scaling rule is approximately **1 mV·µm per nanometer of gate insulator thickness**.

#### Minimum Gate Area from Mismatch Requirements

For a required matching accuracy $\sigma_{spec}$, the minimum gate area is:

$$W \cdot L \geq \left(\frac{A_{VT}}{\sigma_{spec}(\Delta V_T)}\right)^2$$

For six-sigma yield (<1 ppm failures): design spec must satisfy spec $\geq 6\sigma$ of the mismatch parameter.

---

### The Master Mismatch Model

Total device mismatch decomposes into six orthogonal components. Every layout technique targets one or more of these:

$$\sigma^2_{\text{total}} = \sigma^2_{\text{random}} + \sigma^2_{\text{gradient}} + \sigma^2_{\text{LDE}} + \sigma^2_{\text{parasitic}} + \sigma^2_{\text{thermal}} + \sigma^2_{\text{electrical}}$$

| Component                      | Source                                | Layout Technique                     | Mechanism                                       |
| ------------------------------ | ------------------------------------- | ------------------------------------ | ----------------------------------------------- |
| $\sigma^2_{\text{random}}$     | RDF, LER, oxide variation             | Increase $W \cdot L$                 | Spatial averaging: $\sigma \propto 1/\sqrt{WL}$ |
| $\sigma^2_{\text{gradient}}$   | Temperature, doping, stress gradients | Common centroid (ABBA, 2D)           | Centroid coincidence cancels polynomial terms   |
| $\sigma^2_{\text{LDE}}$        | STI stress, WPE, LOD                  | Equal SA/SB, dummies, well centering | Equalize layout geometry parameters             |
| $\sigma^2_{\text{parasitic}}$  | Routing R/C asymmetry                 | Symmetric routing, same metals/vias  | $R_1 = R_2$, $C_1 = C_2$                        |
| $\sigma^2_{\text{thermal}}$    | Temperature differences               | Same isotherm placement              | Equidistant from heat sources                   |
| $\sigma^2_{\text{electrical}}$ | $\Delta V_{DS}$, supply IR drop       | Cascode, symmetric supplies, Kelvin  | Shield drain variation, eliminate IR drops      |

**Implication for the router:** The analog router must simultaneously combat all six components. A layout with perfect common-centroid placement but asymmetric routing will still fail on $\sigma^2_{\text{parasitic}}$. The router's matching cost function must incorporate all six components.

---

### Routing as Spatial Sampling

A device parameter is the spatial integral of a process random field over the layout mask:

$$P_{\text{device}} = \frac{1}{A}\iint_{\text{gate}} p(x,y) \cdot m(x,y) \, dA$$

where $p(x,y)$ is the local process parameter field (dopant density, oxide thickness, stress), $m(x,y)$ is the layout mask function (1 inside the gate, 0 outside), and $A = WL$ is the gate area.

The router manipulates the **spatial sampling function** $m(x,y)$ via guide placement. Routing topology determines how process variation is averaged. This mathematical framing reveals:

- **Larger area** = brute-force averaging of $\sigma^2_{\text{random}}$
- **Common centroid** = symmetry-constrained sampling that cancels low-frequency spatial modes of $p(x,y)$
- **Interdigitation** = 1D periodic sampling that aliases gradients to common-mode
- **Guard rings and shielding** = boundary conditions that attenuate environmental coupling ($p(x,y)$ from outside sources)

---

## Part II: Matching Hierarchy and Router Feature Mapping

### Level 1 — Basic: Same Device, Size, Orientation

**Requirements:** Same transistor type (both NMOS or both PMOS), identical $W$, $L$, number of fingers, identical crystallographic orientation.

**Router action:** The `AnalogNetGroup` database enforces device type matching at netlist input. The router does not control device geometry — this is floorplanning input — but the router **rejects** net groups where device sizes differ beyond a configurable tolerance.

### Level 2 — Intermediate: Proximity, Environment, Dummies

**Requirements:** Close proximity to minimize gradient exposure, identical surroundings (same distance to wells, same STI boundaries, symmetric guard rings), dummy devices at array edges.

**Router action:**

- Guide generation enforces proximity constraints — matched nets receive routing guides that keep their devices within a maximum centroid separation (configurable, default 50 µm).
- The `GuardRingInserter` places symmetric guard rings around matched blocks, ensuring identical STI geometry on all sides.
- DRC rules enforce identical well-edge distances for devices in the same group.

### Level 3 — High Precision: Interdigitation, Thermal Matching, Routing Symmetry

**Requirements:** ABBA pattern interdigitation, matched signals routed together in the same metal layer with identical length, width, and via count. Critical matched devices kept away from hot spots.

**Router action:**

- `MatchedRouter` generates symmetric Steiner trees — all matched nets use identical routing topologies.
- Wire-length balancing adds matching jogs so all nets in a group achieve equal total length.
- Via count balancing ensures all matched nets have the same number of vias.
- Preferred layer constraint forces all matched nets onto the same metal layer (critical: different metal layers have different sheet resistance — M1–M4 ~80 mΩ/□ vs M5 ~20 mΩ/□).
- Thermal hotspot awareness: the floorplanner communicates heat source locations to the router; matched nets are routed along isotherms.

### Level 4 — Extreme Precision: Common Centroid, Stress-Aware, Current-Flow Symmetry

**Requirements:** ABBA or cross-coupled quad placement, coincident centroids in both X and Y, stress-equivalent positioning, anti-parallel routing for thermoelectric cancellation, LDE parameter equality (SA, SB, SCA, SCB, SCC).

**Router action:**

- `MatchedRouter.computeCommonCentroidGuide()` generates routing guides that route to unit cell positions matching the floorplanned common-centroid arrangement.
- For differential pairs: symmetric Steiner tree mirroring around the centroid axis.
- For multi-device matched groups: 2D symmetric guide distribution.
- **Thermoelectric routing:** The router detects when matched devices have anti-parallel current flow (from cross-connection topology) and adds routing jogs to compensate the Seebeck voltage differential.
- LDE-aware guide constraints: SA/SB values from floorplanning are embedded in routing guides as minimum enclosure requirements around each device pin.

---

## Part III: Thermal Awareness

### Temperature Gradient Mechanisms

Power dissipation creates temperature gradients of several °C/mm depending on power density and packaging. The MOSFET threshold voltage temperature coefficient is:

$$V_{th}(T) = V_{th0} - \delta(T - T_0), \quad \delta \approx 1\text{–}4 \text{ mV/°C}$$

A **1 °C gradient** across matched devices causes **1–4 mV** of $V_{th}$ mismatch — devastating for precision analog circuits with sub-millivolt offset requirements.

### Self-Heating at Advanced Nodes

Self-heating is particularly severe in FinFET nodes due to high current density in the 3D fin structure and poor thermal conductivity. At 3 nm, self-heating can cause **≥50 °C** temperature rise. Thermal resistance of short-channel transistors reaches ~34,000 K/W with thermal time constants of ~17 ns. Asymmetric self-heating between matched devices (one conducting more current) directly creates mismatch.

### Router Thermal Cost Function

```zig
pub const ThermalCost = struct {
    // Temperature difference between net's routing path and reference isotherm
    temp_delta: f64,        // °C — from thermal map

    // Gradient across matched group members
    group_gradient: f64,    // °C/µm — thermal slope across differential pair

    // Self-heating estimate from current density
    self_heat_estimate: f64, // °C — from current × thermal_R
};

pub fn computeThermalCost(
    edge: *const RouteEdge,
    group: *const AnalogNetGroup,
    thermal_map: *const ThermalMap,
) f64 {
    const temp_at_edge = thermal_map.query(edge.rect.center());
    const isotherm_ref = thermal_map.referenceTemp();

    var cost: f64 = 0;

    // Cost for deviation from reference isotherm
    cost += @abs(temp_at_edge - isotherm_ref) * thermal_map.temperature_penalty();

    // For matched groups: cost proportional to thermal gradient across group
    if (group.gtype == .differential) {
        const temp_p = thermal_map.query(edge.pin_p_location());
        const temp_n = thermal_map.query(edge.pin_n_location());
        cost += @abs(temp_p - temp_n) * thermal_map.gradient_penalty();
    }

    return cost;
}
```

### Isotherm-Aware Guide Generation

```zig
pub fn generateIsothermGuides(
    router: *AnalogRouter,
    group: *const AnalogNetGroup,
    thermal_map: *const ThermalMap,
) !GuideSet {
    // 1. Extract the reference isotherm (temperature contour)
    const isotherm = try thermal_map.extractIsotherm(group.temperature_tolerance);

    // 2. Route matched nets along the same isotherm
    //    Use isotherm-following pathfinding instead of Manhattan shortest path
    const route = try router.isothermRoute(group.nets, isotherm);

    // 3. If exact isotherm routing is impossible, ensure both nets
    //    cross the same isotherms at the same points
    try router.equalizeIsothermCrossings(route, group);

    return route;
}
```

### Thermal Hotspot Input

```tcl
# Tcl command:
set_thermal_hotspots <list_of_bboxes>
set_thermal_hotspots {{100 100 200 200} {500 500 600 600}}

# Each bbox represents a heat source with estimated power density
# Router avoids placing matched net guides within thermal_gradient_radius of hotspots
# unless unavoidable, in which case both differential pair halves are equidistant
```

---

## Part IV: STI Stress, LOD, and WPE

### STI Stress Physics

STI fill material (SiO₂) has thermal expansion coefficient approximately **5× lower** than silicon. During processing, this mismatch induces compressive stress exceeding **750 MPa** at the STI-silicon boundary.

**NMOS:** Compressive stress along the channel direction **degrades** electron mobility. NMOS $I_{dsat}$ **decreases** by up to **6%** at maximum stress (SA = SB = 0.48 µm vs 1.2 µm in 180 nm).

**PMOS:** Compressive stress **enhances** hole mobility. PMOS $I_{dsat}$ **increases** by up to **9%** under the same conditions.

### BSIM4 LOD Model

LOD = SA + L_drawn + SB. The inverse-distance stress functions in BSIM4:

$$\text{Inv}_{sa} = \frac{1}{SA + 0.5 \cdot L_{\text{drawn}}}, \quad \text{Inv}_{sb} = \frac{1}{SB + 0.5 \cdot L_{\text{drawn}}}$$

For multi-finger devices with $n_f$ fingers:

$$\text{Inv}_{sa,\text{eff}} = \frac{1}{n_f} \sum_{i=1}^{n_f} \frac{1}{SA + SD \cdot (i-1) + 0.5L}$$

where SD is inter-finger spacing. The $V_{th}$ shift **increases** as $L$ decreases.

### WPE Physics

During ion implantation, ions scatter off photoresist sidewalls and embed in silicon adjacent to the well edge, creating enhanced doping extending approximately **1 µm** from the well boundary. $\Delta V_{th}$ reaches **tens of mV** at 0.1 µm spacing.

### BSIM4 WPE Model

The model uses three basis functions integrated over the gate area (SCA, SCB, SCC):

$$V_{TH0} = V_{TH0,\text{noWPE}} + \text{KVTH0WE} \cdot (\text{SCA} + \text{WEB} \cdot \text{SCB} + \text{WEC} \cdot \text{SCC})$$

$$\mu = \mu_{\text{noWPE}} \cdot \left[1 + \text{KU0WE} \cdot (\text{SCA} + \text{WEB} \cdot \text{SCB} + \text{WEC} \cdot \text{SCC})\right]$$

### Router LDE Cost Function

```zig
pub const LDECost = struct {
    // LOD: SA/SB deviation from matched device's reference values
    lod_deviation: f64,     // µm — difference in SA or SB

    // WPE: SCA/SCB/SCC deviation
    wpe_deviation: f64,     // µm — distance from well edge relative to reference

    // Stress gradient across matched group
    stress_gradient: f64,   // MPa/µm
};

pub fn computeLDECost(
    pin: *const PinLocation,
    group: *const AnalogNetGroup,
    floorplan: *const Floorplan,
) f64 {
    const device_params = floorplan.getDeviceParams(pin.device_id);

    var cost: f64 = 0;

    // LOD cost: penalize SA/SB differences from reference
    const sa_ref = group.reference_sa orelse device_params.sa;
    const sb_ref = group.reference_sb orelse device_params.sb;
    cost += @abs(device_params.sa - sa_ref) * LOD_PENALTY;
    cost += @abs(device_params.sb - sb_ref) * LOD_PENALTY;

    // WPE cost: penalize proximity to well edge
    const sc_ref = group.reference_sc orelse 1000.0; // large = far from well
    cost += (sc_ref - device_params.sc) * WPE_PENALTY;

    // Cross-term: SA/SB asymmetry within matched pair
    if (group.gtype == .differential) {
        cost += @abs(device_params.sa - device_params.sb) * ASYMMETRY_PENALTY;
    }

    return cost;
}
```

### LDE-Aware Guide Constraints

```zig
// Guide constraints emitted by floorplanner and consumed by analog router
pub const LDEGuideConstraint = struct {
    device_id: DeviceIdx,
    min_sa: f64,      // µm — minimum gate-to-STI distance on source side
    min_sb: f64,      // µm — minimum gate-to-STI distance on drain side
    max_sa: f64,      // µm — maximum (to avoid dummy poly conflicts)
    max_sb: f64,
    sc_target: f64,   // µm — SCA-based well proximity target
    stress_isotherm: bool, // routing must stay on same isotherm as this device
};

pub fn applyLDEGuides(
    router: *AnalogRouter,
    constraints: []const LDEGuideConstraint,
) !void {
    for (constraints) |c| {
        // Emit keepout zones around device that enforce SA/SB constraints
        const keepout = Rect{
            .x1 = c.device_bbox.x1 - c.min_sa,
            .y1 = c.device_bbox.y1,
            .x2 = c.device_bbox.x2 + c.min_sb,
            .y2 = c.device_bbox.y2,
        };
        try router.addKeepout(keepout, .sti_stress_exclusion);

        // Emit well-edge exclusion zone for WPE
        const well_edge_zone = computeWellProximityZone(c.device_bbox, c.sc_target);
        try router.addKeepout(well_edge_zone, .wpe_exclusion);
    }
}
```

---

## Part V: Parasitic Symmetry — Deep Dive

### Why Geometric Symmetry Is Not Enough

**Parasitic symmetry** — not geometric symmetry — determines matching. A geometrically symmetric layout produces asymmetric parasitics if matched routes cross different coupling environments.

Requirements for true parasitic symmetry:

- **Equal wire length** (not just symmetric geometry)
- **Same metal layers** (different layers have different sheet resistance — M1–M4 ~80 mΩ/□ vs M5 ~20 mΩ/□)
- **Same shielding environment** (identical electromagnetic surroundings)
- **Same via count** (each via adds 1–10 Ω of contact resistance)
- **Equal coupling capacitance** to aggressors

With metal sheet resistance of **50–100 mΩ/□**, 10 squares of routing produce ~1 Ω, yielding **~1 mV/mA** of IR drop — enough to destroy matching achieved by careful device placement.

### Differential Capacitance Metric

The PARSY router introduced the differential capacitance metric:

$$C_{\text{diff}} = \max(C_1, \ldots, C_n) - \min(C_1, \ldots, C_n)$$

The router target is $C_{\text{diff}} \to 0$. This is computed per matched group after routing via the PEX extraction.

### Routing Layer Assignment for Parasitic Matching

```zig
pub const LayerAssignment = enum {
    prefer_lower_metal,   // Lower metals: better coupling to ground plane, more shield
    prefer_upper_metal,   // Upper metals: lower resistance, less coupling
    exact_layer,          // Force exact layer for matched groups
};

pub const ParasiticCost = struct {
    // Resistance mismatch between nets in group
    r_mismatch: f64,      // |R - R_target| / R_target

    // Capacitance mismatch (including coupling)
    c_mismatch: f64,      // |C - C_target| / C_target

    // Coupling delta — differential capacitance
    coupling_delta: f64,  // max(C_coup) - min(C_coup) for matched nets

    // Via count delta
    via_delta: i32,       // abs(via_count - avg_via_count)

    // Layer consistency penalty
    layer_penalty: f64,   // 0 if same as group, else BIG_PENALTY
};
```

### Coupling-Aware Maze Routing

```zig
pub fn computeCouplingCost(
    edge: *const RouteEdge,
    group: *const AnalogNetGroup,
    context: *const RoutingContext,
) f64 {
    // 1. Estimate coupling capacitance to all neighbors
    var coupling_total: f64 = 0;
    const neighbors = context.spatialIndex.queryNeighbors(edge.rect, edge.layer);
    for (neighbors) |neighbor| {
        if (neighbor.net != edge.net and !group.isShielded(neighbor.net)) {
            coupling_total += estimateCouplingCap(edge.rect, neighbor.rect,
                edge.layer, context.pdk);
        }
    }

    // 2. For matched groups: all nets should have similar coupling
    //    Penalize edges that would create coupling asymmetry
    if (group.gtype == .matched or group.gtype == .differential) {
        const target_coupling = context.groupCouplingTarget(group);
        return @abs(coupling_total - target_coupling) * COUPLING_PENALTY;
    }

    return 0;
}
```

---

## Part VI: Shielding — Correct Implementation

### Why Grounded Shields Must Be Grounded

A floating shield is **ineffective**. The effective coupling through a floating shield is $(C_1 \cdot C_2)/(C_1 + C_2)$ — noise still reaches the victim. A grounded shield shunts coupled energy to ground through the low shield-to-ground impedance.

Shield grounding must match the signal reference: analog signals referenced to AVSS use AVSS-connected shields. **Never use digital ground for analog shields** — this directly couples digital switching noise to the analog signal through shield capacitance.

### Driven (Active) Guards

For high-impedance nodes (op-amp inputs, sense amplifier inputs), driven guards at the **same potential** as the sensitive node prevent surface leakage and minimize capacitive loading:

```zig
pub const DrivenGuard = struct {
    signal_net: NetIdx,
    guard_net: NetIdx,    // Same potential as signal_net, not ground
    shield_layer: LayerIdx,
};

// Driven guard routing: shield tracks signal voltage, not ground
// Used for high-impedance nodes where leakage is primary concern
pub fn routeDrivenGuard(
    router: *ShieldRouter,
    guard: *const DrivenGuard,
) !void {
    const route = router.getRoute(guard.signal_net);
    for (route.segments) |seg| {
        // Shield on adjacent layer, tied to signal potential
        const shield_rect = computeShieldRect(seg, guard.shield_layer, router.pdk);
        try router.addShieldWire(guard.guard_net, shield_rect, guard.shield_layer);
        // Via connects shield to signal net (same potential)
        try router.addVia(guard.guard_net, guard.signal_net,
            shield_rect, guard.shield_layer);
    }
}
```

### Faraday Cage Approximation

For RF circuits, the router can approximate on-chip Faraday cages:

```zig
// Surround sensitive block with grounded metal on all available layers
// Via fences create cage walls — spacing < λ/20 of highest frequency
pub fn routeFaradayCage(
    router: *ShieldRouter,
    region: Rect,
    guard_net: NetIdx,
) !void {
    const layers = router.pdk.routingLayers();
    for (layers) |layer| {
        // Top and bottom ground planes
        try router.addShieldWire(guard_net,
            Rect{ .x1 = region.x1, .y1 = region.y2, .x2 = region.x2, .y2 = region.y2 + 1 },
            layer);
        try router.addShieldWire(guard_net,
            Rect{ .x1 = region.x1, .y1 = region.y1 - 1, .x2 = region.x2, .y2 = region.y1 },
            layer);

        // Via fence walls — spacing computed from wavelength
        const max_via_spacing = router.pdk.wavelengthToViaSpacing(MAX_FREQUENCY);
        try router.addViaFence(guard_net, region, layer, max_via_spacing);
    }
}
```

---

## Part VII: Guard Rings — Quantitative

### Guard Ring Effectiveness

| Guard Ring Type                         | Isolation Improvement                 | Mechanism                           |
| --------------------------------------- | ------------------------------------- | ----------------------------------- |
| N+ in p-sub (tied VDD)                  | ~9 dB                                 | Collects electron minority carriers |
| P+ in p-sub (tied VSS)                  | Substrate potential stabilization     | Low-resistance substrate contacts   |
| Deep N-well                             | 20–30+ dB at low freq, ≥4 dB at 3 GHz | Junction isolation tub              |
| Triple-well (P-well in N-well in P-sub) | Best                                  | Complete junction isolation         |

### Guard Ring Design Rules

1. **Complete enclosures** — "a fence, not one fencepost" (Boser). Incomplete rings leak through the gap.
2. **Dedicated supply rails** — shared guard ring contacts reduce isolation through the "telephone effect" where noise picked up on one side transmits through the shared ring.
3. **Width and contact density** — wider rings with more contacts improve isolation but consume area.

### Guard Ring Spacing to Inner Circuitry

```zig
pub const GuardRingConfig = struct {
    ring_type: GuardRingType,
    width: f64,           // µm — ring width (minimum = pdk.min_width[layer])
    spacing: f64,         // µm — spacing from inner circuitry
    contact_spacing: f64, // µm — substrate/well contact pitch
    via_count: u32,       // via chain count for low impedance
};

// For analog blocks requiring maximum isolation:
const ANALOG_GUARD_CONFIG = GuardRingConfig{
    .ring_type = .deep_nwell,
    .width = 2.0,          // µm
    .spacing = 1.0,         // µm — STI stress relief + WPE avoidance
    .contact_spacing = 0.5, // µm — dense contacts for low impedance
    .via_count = 3,         // via chain for deep N-well contact
};
```

### Substrate Coupling Physics

The substrate acts as a distributed 3D resistive-capacitive network. Coupling occurs through:

- **Capacitive paths** — source/drain depletion capacitances, decreasing impedance at high frequency
- **Resistive paths** — injected substrate current creates voltage drops affecting threshold via body effect ($g_{mb}/g_m \approx 0.1$–$0.3$)
- **Minority carrier injection** — forward-biased junctions inject electrons in p-sub that diffuse tens of micrometers before recombining

For epitaxial substrates (~0.01 Ω·cm bulk), the low-resistivity substrate acts nearly as a single equipotential — coupling is largely **independent of distance**. On lightly-doped substrates (~1–20 Ω·cm), distance and guard rings are effective.

### Ground Bounce Aware Routing

Ground bounce from bond wire inductance (~1 nH/mm) combined with nanosecond-rise-time digital switching produces **tens of millivolts** of supply noise. The router accounts for this by:

1. **Separate analog/digital supply routing domains** — analog nets are never routed over digital switching regions
2. **Decoupling capacitor placement awareness** — router avoids routing sensitive nets near decoupling capacitor locations that could inject charge
3. **Bond wire inductance estimation** — for packages with significant $L_{bond}$, the router adds width margins to analog supply traces

---

## Part VIII: Higher-Order Matching Patterns

### ABBA Mathematical Basis

For $n$ fingers at equally spaced positions $x_k = k \cdot d$ with a linear gradient $P(x) = P_0 + \alpha x$:

$$\bar{P}_A = P_0 + \alpha \cdot \frac{1}{n}\sum_{k \in A} x_k, \quad \bar{P}_B = P_0 + \alpha \cdot \frac{1}{n}\sum_{k \in B} x_k$$

For symmetric interdigitation (ABBA endpoints): $\sum_{k \in A} x_k = \sum_{k \in B} x_k$, so $\bar{P}_A = \bar{P}_B$ — **perfect cancellation of linear gradients**.

### ABBABAAB — Second-Order Cancellation

The $n$th-order central symmetrical pattern cancels gradients up to $(n-1)$th order. ABBABAAB (8 cells) cancels gradients up to **second order**.

Construction: take the $(n-1)$th-order pattern and append its mirror with device labels swapped:

$$\text{ABBA} \to \text{ABBABAAB}$$

Each additional level of nesting cancels higher-order polynomial terms.

### The Dispersion Principle

**Boser (Berkeley EE240B):** ABABBABA is preferable to ABBAABBA because fewer contiguous runs of the same device produce better averaging of higher-order spatial variation.

The router generates dispersion-optimized patterns:

```zig
pub const InterdigitationPattern = enum {
    abba,           // 4 cells — cancels linear gradients
    abbabaab,       // 8 cells — cancels up to 2nd order
    ababbbbaa,      // 10 cells — dispersion-optimized
    cross_coupled,   // 2×2 grid for 2D gradient cancellation
};

pub fn generateInterdigitatedGuides(
    router: *AnalogRouter,
    group: *const AnalogNetGroup,
    pattern: InterdigitationPattern,
) !GuideSet {
    const devices = router.floorplan.getMatchedDevices(group);
    const ordering = switch (pattern) {
        .abba => &.{0, 1, 1, 0},           // A-B-B-A
        .abbabaab => &.{0, 1, 1, 0, 1, 0, 0, 1}, // A-BB-A-B-A-AA-B
        .cross_coupled => generateCrossCoupledOrdering(devices),
        // ...
    };
    return router.routeInOrdering(group, ordering);
}
```

### 2D Common Centroid — Cross-Coupled Quad

Canonical 2D pattern (4 cells):

$$\begin{bmatrix} A & B \\ B & A \end{bmatrix}$$

Each device's centroid lies at the geometric center in **both x and y**, cancelling linear gradients in any direction. The $x^2$ and $y^2$ quadratic terms also cancel, but the cross-term $exy$ does **not** cancel for a simple 2×2. To cancel the cross-term, a 2×4 or 4×4 checkerboard pattern is required.

---

## Part IX: Passive Device Routing

### Resistor Matching

Resistor mismatch model follows Pelgrom:

$$\sigma\!\left(\frac{\Delta R}{R}\right) = \frac{A_R}{\sqrt{\text{Area}}}$$

Current crowding at contacts and bends is modeled by transfer length $L_T = \sqrt{\rho_c / R_s}$. A right-angle bend has effective resistance of approximately **0.56 squares** rather than a full square.

Key routing requirements for matched resistors:

- **Unit segments** in interdigitated CC arrangements
- **Even number of segments** for serpentine layouts with half oriented in each direction (cancels thermoelectric effects)
- **Start and end contacts close together** (minimizes differential Seebeck voltage)
- **Identical contact ratios** (body + contact resistance must maintain geometric ratios)

```zig
pub const ResistorMatchGroup = struct {
    name: []const u8,
    segments: []const ResistorSegment,
    total_target: f64,      // Ω — target resistance
    tolerance: f32,         // e.g., 0.01 for 1% matching
};

pub fn routeMatchedResistors(
    router: *AnalogRouter,
    group: *const ResistorMatchGroup,
) !void {
    // 1. Route each segment with identical geometry
    for (group.segments) |seg| {
        try router.routeSegment(seg.net, seg.route);
    }

    // 2. Verify total resistance matches within tolerance
    //    (via width tuning if needed — wider = lower R)
    const extracted = try router.pex.extractResistance(group);
    if (!extracted.withinTolerance(group.tolerance)) {
        try router.adjustWidths(group, extracted);
    }

    // 3. Verify via counts are balanced across segments
    try router.balanceViaCounts(group);
}
```

### Capacitor Array Routing

For DAC capacitor arrays, routing between capacitor plates and switches must be **parasitic-symmetric**:

```zig
pub const CapArrayMatchGroup = struct {
    unit_capacitors: u32,   // number of unit elements
    array_pattern: CapArrayPattern, // .spiral | .chessboard | .block_chessboard
    top_plate_net: NetIdx,
    bottom_plate_net: NetIdx,
};

// Unit capacitors placed in common-centroid pattern
// Routing must be symmetric: all top plates reach the top plate net
// via identical-length routes on the same metal layer
pub fn routeCapacitorArray(
    router: *AnalogRouter,
    group: *const CapArrayMatchGroup,
) !void {
    const unit_positions = router.floorplan.getCapacitorPositions(group);
    const centroid = computeCentroid(unit_positions);

    for (unit_positions) |pos| {
        // Route from unit cap to top plate net
        // All routes must have identical length (measured from centroid)
        const route_length = computeRouteLength(pos, centroid, group.top_plate_net);
        const jogs = router.generateMatchingJogs(pos, route_length, centroid);
        try router.addRoute(group.top_plate_net, jogs);

        // Bottom plate routing (typically substrate, may be common)
        try router.addRoute(group.bottom_plate_net, pos.bottom_plate_route);
    }
}
```

---

## Part X: Reference Distribution and Kelvin Connections

### IR Drop Aware Routing

With metal sheet resistance of 50–100 mΩ/□, voltage errors are proportional to current × routing resistance. For reference circuits:

$$V_{\text{ref}} = I_{\text{out}} \times (R_{\text{load}} + R_{\text{parasitic}})$$

The router computes IR drop budgets per net and flags violations:

```zig
pub const IRDropBudget = struct {
    max_drop: f64,          // mV — maximum allowed IR drop
    segment_resistances: []const f64,  // Ω per segment
    segment_currents: []const f64,      // A per segment
};

pub fn verifyIRDropBudget(
    router: *AnalogRouter,
    net: NetIdx,
    budget: *const IRDropBudget,
) !bool {
    var total_drop: f64 = 0;
    for (budget.segment_resistances, budget.segment_currents) |r, i| {
        total_drop += r * i;
    }
    return total_drop <= budget.max_drop;
}
```

### Star Routing

Each circuit receiving a reference voltage gets its own **dedicated, non-shared** path from the source. Individual traces branch independently to each pin, preventing one circuit's current draw from shifting the reference seen by others.

```zig
// Star routing: one branch per load, no shared segments
pub fn routeStar(
    router: *AnalogRouter,
    source: PinLocation,
    loads: []const PinLocation,
) !void {
    const steiner = try router.computeSteinerTree(source, loads);
    // But unlike normal Steiner, we prohibit shared branches:
    // Each load gets a dedicated path from the star point
    for (loads) |load| {
        const branch = try router.computeBranch(steiner.starPoint(), load);
        // Verify no other load uses any segment of this branch
        try router.reserveBranch(branch, load);
    }
}
```

### Kelvin (4-Wire) Connections

Separates current-carrying and voltage-sensing paths — critical for bandgap references and precision current mirrors:

```zig
pub const KelvinConnection = struct {
    force_net: NetIdx,     // Carries high current
    sense_net: NetIdx,     // Carries no current (or microamp sense current)
    force_pins: []const PinLocation,
    sense_pins: []const PinLocation,
};

// Kelvin: sense routing uses wider metal for lower resistance
// but must not share any segment with force routing
pub fn routeKelvin(
    router: *AnalogRouter,
    kelvin: *const KelvinConnection,
) !void {
    // Force path: optimized for current handling (width, via count)
    try router.routeLowImpedance(kelvin.force_net, kelvin.force_pins);

    // Sense path: optimized for accuracy (separate route, no IR drop)
    // Routes in parallel to force path but with no shared segments
    try router.routeSenseOnly(kelvin.sense_net, kelvin.sense_pins);

    // Ensure sense pins are at exact same geometry as force pins
    // (same metal layer, same distance from device)
    try router.matchSenseToForceGeometry(kelvin);
}
```

---

## Part XI: Density and CMP Awareness

### CMP Physics

Chemical Mechanical Polishing removes material at rates dependent on local pattern density. Areas with lower metal density experience higher effective pressure and more aggressive polishing (**dishing**), while high-density areas polish more slowly (**erosion**). Uncontrolled density can produce **767 Å** of post-CMP topography variation, reducible to **152 Å** with proper dummy fill.

### Dummy Fill Exclusion Zones

The router maintains exclusion zones where dummy fill is prohibited near sensitive analog circuits:

```zig
pub const DummyFillExclusion = struct {
    region: Rect,
    reason: FillExclusionReason,
    min_distance: f64,  // µm — minimum distance from region edge
};

pub const FillExclusionReason = enum {
    matched_capacitor,   // Fill changes fringe capacitance on matched caps
    sensitive_resistor,  // Fill affects resistor geometry and value
    high_impedance_node, // Fill increases parasitic capacitance to high-Z node
    guard_ring_boundary, // Fill would short to guard ring
};

// The fill engine consults this database before placing dummy metal
pub fn queryFillExclusion(
    router: *AnalogRouter,
    region: Rect,
) ?DummyFillExclusion {
    return router.fillExclusionZones.findOverlapping(region);
}
```

### Density-Aware Routing

The router balances density during routing to reduce post-CMP variation:

```zig
pub const DensityAwareRouting = struct {
    target_density: f64,    // 0.0–1.0 — target metal density
    min_density: f64,       // Minimum to avoid erosion
    max_density: f64,       // Maximum to avoid dishing
    exclusion_zones: []const DummyFillExclusion,
};

// During routing, if local density would exceed max_density,
// router prefers jog insertion in low-density areas instead
pub fn densityBalancedRoute(
    router: *AnalogRouter,
    net: NetIdx,
    target: PinLocation,
    density: *const DensityMap,
) !Route {
    var candidates = router.computeRouteCandidates(net, target);

    // Filter candidates that would violate density rules
    candidates = candidates.filter(|c| {
        const new_density = density.project(c.rect);
        return new_density <= DENSITY_MAX and new_density >= DENSITY_MIN;
    });

    // Among valid candidates, prefer those that improve local density balance
    candidates.sortBy(|a, b| {
        const balance_a = density.localBalance(a.rect);
        const balance_b = density.localBalance(b.rect);
        return balance_a < balance_b;  // prefer more balanced areas
    });

    return candidates[0];
}
```

---

## Part XII: Advanced Node Challenges

### LDE Dominance Below 65 nm

At nodes ≤40 nm, **LDE-induced systematic mismatch exceeds random mismatch**. Ignoring LDE at advanced nodes can produce **up to 140% error** in series resistance and **25% error** in total capacitance.

Standard CC placement cancels only linear gradients. At advanced nodes, the increasingly nonlinear variation profiles require:

- Higher-order ABBA patterns (ABBABAAB, ABABBBAAA)
- More dispersed layouts
- Exhaustive post-layout LDE extraction

### FinFET-Specific Routing Constraints

Transistor width in FinFETs is **quantized** to integer multiples of fin pitch. The analog router loses continuous $W/L$ tuning — only discrete widths are available.

```zig
pub const FinFETConstraints = struct {
    fin_pitch: f64,        // µm — distance between fin centers
    fin_height: f64,       // µm — height of fin
    min_fins: u32,          // minimum number of fins
    max_fins: u32,          // maximum number of fins
    // Width is quantized: W_eff = n_fins × (2*H_fin + W_fin)
};
```

Routing must account for:

- **Gate Line End Effect (GLE)** — 6.3% $I_{dsat}$ shift for nFET
- **Poly Spacing Effect (PSE)**
- **Neighboring Diffusion Effect (NDE)**
- **Metal Boundary Effect (MBE)** — all modeled in BSIM-CMG

### GAA/Nanosheet Routing

GAA/nanosheet FETs at ≤3 nm quantize width by nanosheet count. Self-heating is more severe due to stacked 3D channel structure. Routing for GAA must account for:

- Thermal coupling between stacked channels
- Routing over active area creates stress that affects nanosheet arrays
- Wider wires are critical for thermal dissipation

### Multi-Patterning Aware Routing

At 7 nm without EUV, Self-Aligned Quadruple Patterning (SAQP) introduces overlay errors (~0.6–2.0 nm) and pattern-dependent systematic variations. RC characteristics are **color-dependent** even on the same metal layer.

The router tracks color assignment for multi-patterned layers and ensures matched nets use the **same color** to avoid systematic resistance variation:

```zig
pub const MultiPatternColor = struct {
    layer: LayerIdx,
    colors: u8,        // 2 for double-patterning, 4 for SAQP
    assignment: std.AutoHashMap(NetIdx, u8),  // net → color
};

// Matched nets must use same color on multi-patterned layers
// to avoid systematic RC variation from color-dependent etching
pub fn verifyColorConsistency(
    router: *AnalogRouter,
    group: *const AnalogNetGroup,
) !bool {
    var first_color: u8 = undefined;
    for (group.nets) |net| {
        const color = router.multiPattern.getColor(net, group.route_layer);
        if (first_color == undefined) {
            first_color = color;
        } else if (color != first_color) {
            return false;  // Color mismatch — will cause RC asymmetry
        }
    }
    return true;
}
```

---

## Part XIII: Common Failure Modes

### Failure Mode 1: Perfect Centroid + Bad Routing

A CC placement guarantees equal device parameters, but asymmetric interconnect (different wire lengths, via counts, metal layers) nullifies matching. In FinFET nodes with high per-unit wire/via resistance, even a **single extra via** causes significant mismatch.

**Router mitigation:** The PEX feedback loop in Stage 4 extracts per-net R, C, and via count. The `MatchReport` flags any net in a matched group that differs from the group mean by more than `tolerance`. The router then inserts compensation jogs or dummy vias to restore symmetry.

### Failure Mode 2: Symmetric Geometry + Asymmetric Current Flow

Matched devices with identical layout but current flowing in opposite physical directions introduce stress-induced mobility anisotropy and thermoelectric offsets.

**Router mitigation:** The router detects cross-connection topologies where matched devices have anti-parallel current flow and adds compensating routing:

```zig
pub fn detectAntiParallelFlow(
    router: *AnalogRouter,
    group: *const AnalogNetGroup,
) !bool {
    // If matched nets are cross-connected (output of one drives input of other),
    // current flow through the shared device is anti-parallel
    const connection_pattern = router.netlist.getConnectionPattern(group);
    return connection_pattern.isCrossCoupled();
}

// If anti-parallel flow detected, add Seebeck compensation jogs
pub fn addSeebeckCompensation(
    router: *AnalogRouter,
    group: *const AnalogNetGroup,
) !void {
    // Serpentine the longer net to introduce compensating thermoelectric EMF
    // anti-parallel flow in matched resistors: half in each direction cancels Seebeck
    const net_lengths = try router.computeNetLengths(group);
    const max_len = @max(net_lengths);
    for (group.nets, net_lengths) |net, len| {
        if (len < max_len) {
            const delta = max_len - len;
            try router.addThermoCompensationJogs(net, delta / 2);
        }
    }
}
```

### Failure Mode 3: Missing Dummies

Edge devices exposed to different etch rates, mechanical stress, LOD values, and fringe capacitance create systematic parameter shifts of 10+ mV in $V_{th}$.

**Router mitigation:** The `GuardRingInserter` automatically places dummy devices at the periphery of matched arrays. DRC rules enforce that no routing occurs in the SA/SB exclusion zone adjacent to active devices.

### Failure Mode 4: Ignoring LDE at Advanced Nodes

At 65 nm and below, LOD and WPE combined cause $V_{th}$ variations even with standard PDK layouts. LDE can dominate over random mismatch entirely.

**Router mitigation:** The LDE cost function in the routing maze expansion penalizes guide placement that would create SA/SB asymmetry between matched devices. Floorplan integration ensures LDE parameters are equalized before routing begins.

### Failure Mode 5: Poor Substrate Isolation

Switching noise coupling through the substrate degrades SNR and creates noise-induced dynamic mismatch.

**Router mitigation:** Deep N-well insertion for analog blocks creates junction isolation from digital switching noise. Guard ring density and contact spacing are verified against the isolation target (dB improvement). The router avoids routing analog nets over digital switching regions.

---

## Part XIV: Data Structures (Enhanced)

### AnalogNetGroup (Enhanced)

```zig
// src/router/analog_router.zig

pub const AnalogGroupType = enum {
    differential,    // net_p, net_n — matched with inversion
    matched,         // multiple nets — matched within tolerance
    shielded,        // net with dedicated shield
    kelvin,         // sense/force pair — separate routing
    resistor_matched, // resistor segments requiring CC routing
    capacitor_array,  // DAC-style unit cap array
};

pub const AnalogNetGroup = struct {
    name: []const u8,
    gtype: AnalogGroupType,
    nets: []const NetIdx,

    // Matching tolerance
    tolerance: f32,          // e.g., 0.05 for 5% R/C matching

    // Layer preference
    preferred_layer: ?LayerIdx,

    // For shielded nets: which net provides the shield
    shield_net: ?NetIdx,

    // For Kelvin: separate force/sense nets
    force_net: ?NetIdx,
    sense_net: ?NetIdx,

    // Route priority (0 = highest / most critical)
    route_priority: u8,

    // LDE constraints for this group
    lde_constraints: ?LDEGuideConstraint,

    // Thermal constraints
    thermal_tolerance: ?f32,   // °C — max allowed thermal gradient across group
    isotherm_target: ?f32,     // °C — temperature the routing should maintain

    // Common-centroid pattern
    centroid_pattern: ?CentroidPattern,

    // Interdigitation ordering (if applicable)
    interdigitation: ?InterdigitationPattern,
};

pub const CentroidPattern = struct {
    devices: []const DeviceIdx,
    positions: []const Point,  // 2D positions of each unit cell
    order: []const u32,        // which device at which position
};

pub const MatchReport = struct {
    group: *const AnalogNetGroup,
    net_results: []const NetMatchResult,
    passes_tolerance: bool,

    // Mismatch ratios
    r_ratio: f32,             // max(R) / min(R) - 1.0
    c_ratio: f32,             // max(C) / min(C) - 1.0
    length_ratio: f32,         // max(length) / min(length) - 1.0
    via_count_delta: i32,      // abs(via_count_1 - via_count_2)
    coupling_delta: f32,       // max(C_coup) - min(C_coup) [fF]

    // LDE mismatch (advanced nodes)
    lod_delta: ?f32,           // µm — SA/SB asymmetry
    wpe_delta: ?f32,           // µm — SCA deviation

    // Thermal mismatch
    thermal_gradient: ?f32,   // °C across matched group
};

pub const NetMatchResult = struct {
    net: NetIdx,
    total_length: f32,
    layer_lengths: []const f32,    // per-layer breakdown
    via_count: u32,
    total_resistance: f32,
    total_capacitance: f32,
    coupling_caps: []const CouplingCap,

    // LDE metrics
    sa: ?f32,   // µm — gate-to-STI distance source side
    sb: ?f32,   // µm — gate-to-STI distance drain side
    sc: ?f32,   // µm — well proximity parameter
};
```

---

## Part XV: Stage 2: Matched Router (Enhanced)

### 2.1 Symmetric Steiner Tree Generation

**Problem:** Matched nets need identical routing topologies.

**Solution:** Generate a single Steiner tree, then mirror it for the paired net.

```zig
pub fn generateSymmetricGuide(
    router: *AnalogRouter,
    group: *const AnalogNetGroup,
    pins: []const PinLocation,
) !GuideSet {
    const bbox = computeBoundingBox(pins);

    const steiner = try router.generateSteinerTree(pins, .manhattan);

    if (group.gtype == .differential) {
        const axis = bbox.centerX();
        const mirrored = mirrorSteinerTree(steiner, axis);
        return .{
            .net_p = steiner,
            .net_n = mirrored,
        };
    }

    if (group.gtype == .matched) {
        // All matched nets use the same Steiner tree
        return .{ .shared = steiner };
    }

    if (group.gtype == .resistor_matched) {
        // Unit segments routed in CC pattern — compute 2D positions
        const cc_positions = try router.computeCentroidPositions(group, pins);
        return try router.routeInCentroidPattern(steiner, cc_positions);
    }

    return .{ .shared = steiner };
}
```

### 2.2 Wire-Length Matching (Enhanced)

```zig
pub fn balanceWireLengths(
    router: *AnalogRouter,
    group: *const AnalogNetGroup,
) !void {
    var net_lengths = std.ArrayList(f32).init(allocator);
    for (group.nets) |net_idx| {
        const length = try router.routeNet(net_idx);
        try net_lengths.append(length);
    }

    const target = @min(net_lengths.items);

    for (group.nets, net_lengths.items) |net_idx, len| {
        if (len > target) {
            const delta = len - target;
            try router.addMatchingJogs(net_idx, delta, group);
        }
    }
}

fn addMatchingJogs(
    router: *AnalogRouter,
    net_idx: NetIdx,
    extra_length: f32,
    group: *const AnalogNetGroup,
) !void {
    // Find a "silent segment" — a straight run with no vias or terminals
    const silent_segments = try router.findSilentSegments(net_idx);
    if (silent_segments.len == 0) {
        // No silent segments — must use jog on a non-critical segment
        // Add jog, but first verify DRC
        const last_seg = router.getLastSegment(net_idx);
        const jog_seg = Segment{
            .layer = last_seg.layer,
            .orient = .horizontal,
            .length = extra_length,
            .width = router.pdk.min_width[last_seg.layer],
        };
        if (try router.drc.check(jog_seg, last_seg.layer)) {
            try router.insertSegment(net_idx, jog_seg);
        }
        return;
    }

    // Prefer silent segment closest to the centroid of the matched group
    // to minimize thermal gradient impact
    const centroid = router.computeGroupCentroid(group);
    const best_seg = router.findClosestTo(silent_segments, centroid);
    const jog_seg = Segment{
        .layer = best_seg.layer,
        .orient = .horizontal,
        .length = extra_length,
        .width = router.pdk.min_width[best_seg.layer],
    };
    try router.insertSegment(net_idx, jog_seg);
}
```

### 2.3 Via Count Balancing (Enhanced)

```zig
pub fn balanceViaCounts(
    router: *AnalogRouter,
    group: *const AnalogNetGroup,
) !void {
    var via_counts = std.AutoHashMap(NetIdx, u32).init(allocator);
    for (group.nets) |net_idx| {
        const count = router.countVias(net_idx);
        try via_counts.put(net_idx, count);
    }

    const max_vias = @max(via_counts.values());
    const min_vias = @min(via_counts.values());

    if (max_vias - min_vias > 1) {
        for (group.nets) |net_idx| {
            const count = via_counts.get(net_idx);
            if (count < max_vias) {
                // Try to add dummy via on a silent segment
                const silent_segs = try router.findSilentSegments(net_idx);
                for (silent_segs) |seg| {
                    const dummy_via = Via{
                        .layer = seg.layer,
                        .rect = seg.rect,
                        .net = net_idx,
                    };
                    if (try router.drc.checkVia(dummy_via)) {
                        try router.addDummyVia(net_idx, dummy_via);
                        break;
                    }
                }
                // If no DRC-clean silent segment found, allow delta > 1
                // This is logged as a warning in the MatchReport
            }
        }
    }
}
```

### 2.4 Parasitic Symmetry Cost Function (Enhanced)

```zig
pub const MatchedRoutingCost = struct {
    base_cost: f64,           // Manhattan length

    // Parasitic mismatch cost
    r_mismatch: f64,          // |R - R_target| / R_target
    c_mismatch: f64,          // |C - C_target| / C_target

    // Coupling cost — matched nets should have same coupling
    coupling_delta: f64,       // |C_coup_1 - C_coup_2| / C_target

    // Via count delta
    via_delta: i32,           // abs(via_count - avg_via_count)

    // Layer consistency — all matched nets should use same layers
    layer_penalty: f64,       // 0 if same as group, else BIG_PENALTY

    // Thermal cost
    thermal_cost: f64,        // from thermal map

    // LDE cost
    lde_cost: f64,            // SA/SB/WPE deviation
};

pub fn computeMatchedCost(
    router: *AnalogRouter,
    edge: *const RouteEdge,
    group: *const AnalogNetGroup,
    context: *const RoutingContext,
) f64 {
    var cost = MatchedRoutingCost{
        .base_cost = edge.manhattanLength() * context.layerCost(edge.layer),
        .r_mismatch = 0,
        .c_mismatch = 0,
        .coupling_delta = 0,
        .via_delta = 0,
        .layer_penalty = 0,
        .thermal_cost = 0,
        .lde_cost = 0,
    };

    // Layer consistency
    if (group.preferred_layer) |pref| {
        if (edge.layer != pref) {
            cost.layer_penalty = 1000.0;
        }
    }

    // Estimate R and C
    const r_est = estimateResistance(edge, context.pdk);
    const c_est = estimateCapacitance(edge, context.pdk);

    // Thermal cost
    if (context.thermal_map) |thermal| {
        cost.thermal_cost = computeThermalCost(edge, group, thermal);
    }

    // LDE cost
    if (context.floorplan) |fp| {
        cost.lde_cost = computeLDECost(edge.pin, group, fp);
    }

    return cost.base_cost
        + cost.r_mismatch * 100.0
        + cost.c_mismatch * 100.0
        + cost.coupling_delta * 50.0
        + cost.via_delta * 10.0
        + cost.layer_penalty
        + cost.thermal_cost * 200.0   // thermal penalty weight
        + cost.lde_cost * 150.0;       // LDE penalty weight
}
```

---

## Part XVI: Stage 2: ShieldRouter (Enhanced)

### Shield Wire Generation

```zig
pub const ShieldRouter = struct {
    pdk: *const Pdk,
    spatial_index: *DRCSpatialIndex,
};

pub fn routeShielded(
    router: *ShieldRouter,
    signal_net: NetIdx,
    shield_net: NetIdx,
    shield_layer: LayerIdx,
) !void {
    const route = router.getRoute(signal_net);

    for (route.segments) |seg| {
        const shield_rect = computeShieldRect(seg, shield_layer, router.pdk);

        if (!router.drc.check(shield_rect, shield_layer)) {
            continue;  // Skip conflicting segments
        }

        try router.addShieldWire(shield_net, shield_rect, shield_layer);
        try router.addViaToGround(shield_net, shield_rect, shield_layer);
    }
}

fn computeShieldRect(
    seg: *const RouteSegment,
    shield_layer: LayerIdx,
    pdk: *const Pdk,
) Rect {
    const offset = pdk.min_spacing[shield_layer] + pdk.min_width[shield_layer] / 2;

    return switch (seg.orient) {
        .horizontal => Rect{
            .x1 = seg.rect.x1 - offset,
            .y1 = seg.rect.y1 - pdk.min_width[shield_layer] / 2,
            .x2 = seg.rect.x2 + offset,
            .y2 = seg.rect.y2 + pdk.min_width[shield_layer] / 2,
        },
        .vertical => Rect{
            .x1 = seg.rect.x1 - pdk.min_width[shield_layer] / 2,
            .y1 = seg.rect.y1 - offset,
            .x2 = seg.rect.x2 + pdk.min_width[shield_layer] / 2,
            .y2 = seg.rect.y2 + offset,
        },
    };
}
```

---

## Part XVII: Stage 2: GuardRingInserter (Enhanced)

### Guard Ring Placement

```zig
pub const GuardRingType = enum {
    p_plus,         // P+ in N-well, tied to VDD
    n_plus,         // N+ in P-sub, tied to VSS
    deep_nwell,     // Deep N-well for analog-digital isolation
    substrate,       // Substrate contact ring
};

pub const GuardRing = struct {
    ring_type: GuardRingType,
    bbox: Rect,
    layer: LayerIdx,
    net: NetIdx,
    width: f32,
    spacing: f32,
    isolation_target_db: ?f32,  // dB isolation target
};

pub fn insertGuardRing(
    inserter: *GuardRingInserter,
    region: Rect,
    ring_type: GuardRingType,
    net: NetIdx,
) !GuardRing {
    const pdk = inserter.pdk;

    const ring_width = pdk.min_width[ring_type.toLayer()];
    const ring_spacing = pdk.min_spacing[ring_type.toLayer()];

    const ring_rect = Rect{
        .x1 = region.x1 - ring_spacing - ring_width / 2,
        .y1 = region.y1 - ring_spacing - ring_width / 2,
        .x2 = region.x2 + ring_spacing + ring_width / 2,
        .y2 = region.y2 + ring_spacing + ring_width / 2,
    };

    const ring_shape = computeDonut(outer, inner);

    try inserter.drc.check(ring_shape, ring_type.toLayer());
    try inserter.addShape(net, ring_shape, ring_type.toLayer());

    const contacts = inserter.generateContacts(ring_rect, ring_type, net);
    try inserter.addShapes(contacts);

    return GuardRing{
        .ring_type = ring_type,
        .bbox = ring_rect,
        .layer = ring_type.toLayer(),
        .net = net,
        .width = ring_width,
        .spacing = ring_spacing,
    };
}
```

---

## Part XVIII: Stage 4: PEX + Match Analysis (Enhanced)

### Matching Analysis (Enhanced)

```zig
pub fn analyzeMatching(
    pex: *PexEngine,
    groups: []const *const AnalogNetGroup,
) ![]const MatchReport {
    var reports = std.ArrayList(MatchReport).init(allocator);

    for (groups) |group| {
        var net_results = std.ArrayList(NetMatchResult).init(allocator);
        for (group.nets) |net_idx| {
            const result = try pex.extractNet(net_idx);
            try net_results.append(result);
        }

        const match_result = try computeMatchReport(group, net_results.items);
        try reports.append(match_result);
    }

    return reports.items;
}

fn computeMatchReport(
    group: *const AnalogNetGroup,
    results: []const NetMatchResult,
) !MatchReport {
    var min_r = f32.max, max_r = f32.min;
    var min_c = f32.max, max_c = f32.min;
    var min_len = f32.max, max_len = f32.min;
    var total_vias: u32 = 0;
    var max_coupling_delta: f32 = 0;

    for (results) |r| {
        min_r = @min(min_r, r.total_resistance);
        max_r = @max(max_r, r.total_resistance);
        min_c = @min(min_c, r.total_capacitance);
        max_c = @max(max_c, r.total_capacitance);
        min_len = @min(min_len, r.total_length);
        max_len = @max(max_len, r.total_length);
        total_vias += r.via_count;

        // Compute coupling delta
        for (r.coupling_caps) |cap| {
            const delta = @abs(cap.value - group.target_coupling);
            max_coupling_delta = @max(max_coupling_delta, delta);
        }
    }

    const r_ratio = if (min_r > 0) (max_r / min_r) - 1.0 else 0.0;
    const c_ratio = if (min_c > 0) (max_c / min_c) - 1.0 else 0.0;
    const length_ratio = if (min_len > 0) (max_len / min_len) - 1.0 else 0.0;

    const avg_vias = @as(f32, @floatFromInt(total_vias)) / @as(f32, @floatFromInt(results.len));
    var max_via_delta: i32 = 0;
    for (results) |r| {
        const delta = @abs(@as(i32, @intCast(r.via_count)) - @as(i32, @intFromFloat(avg_vias)));
        max_via_delta = @max(max_via_delta, delta);
    }

    return MatchReport{
        .group = group,
        .net_results = results,
        .passes_tolerance = r_ratio <= group.tolerance
            and c_ratio <= group.tolerance
            and length_ratio <= group.tolerance
            and max_via_delta <= 1
            and max_coupling_delta <= group.coupling_tolerance,
        .r_ratio = r_ratio,
        .c_ratio = c_ratio,
        .length_ratio = length_ratio,
        .via_count_delta = max_via_delta,
        .coupling_delta = max_coupling_delta,
        .lod_delta = try computeLODMismatch(group, results),
        .wpe_delta = try computeWPEMismatch(group, results),
        .thermal_gradient = computeThermalGradient(group),
    };
}
```

### Repair Loop (Enhanced)

```zig
pub const RoutingResult = enum {
    success,
    drc_violation,
    mismatch_exceeded,
    unroutable,
};

pub fn routeWithPexFeedback(
    router: *AnalogRouter,
    group: *const AnalogNetGroup,
    max_iterations: u32,
) !RoutingResult {
    for (0..max_iterations) |iter| {
        try router.routeGroup(group);

        const reports = try router.pex.analyzeMatching(&.{group});

        if (reports[0].passes_tolerance) {
            return .success;
        }

        const report = reports[0];

        if (report.r_ratio > group.tolerance) {
            try router.adjustWidthsForResistance(group, report);
        }

        if (report.c_ratio > group.tolerance) {
            try router.adjustLayersForCapacitance(group, report);
        }

        if (report.length_ratio > group.tolerance) {
            try router.balanceWireLengths(group);
        }

        if (report.via_count_delta > 1) {
            try router.balanceViaCounts(group);
        }

        if (report.coupling_delta > group.coupling_tolerance) {
            try router.rebalanceCoupling(group, report);
        }

        if (report.lod_delta != null and report.lod_delta > LOD_TOLERANCE) {
            try router.requestLDEGuidesFromFloorplan(group);
        }

        if (report.thermal_gradient != null and
            report.thermal_gradient > group.thermal_tolerance) {
            try router.adjustGuidesForThermal(group, report);
        }

        try router.updateGuides(group);
    }

    return .mismatch_exceeded;
}
```

---

## Part XIX: DRC Rule Matrix (Enhanced)

### Rules Enforced During Routing

| Rule               | Enforced  | Method                            |
| ------------------ | --------- | --------------------------------- |
| Minimum spacing    | ✅ Yes    | Spatial index query, O(log n + k) |
| Minimum width      | ✅ Yes    | O(1) width check                  |
| Via enclosure      | ✅ Yes    | O(1) per-side check               |
| Via-to-via spacing | ✅ Yes    | O(log n + m) query                |
| Same-net spacing   | ✅ Yes    | Net ID filter                     |
| Wide metal spacing | ✅ Yes    | O(1) width + spacing              |
| EOL spacing        | ⚠️ Commit | Retroactive zone blocking         |
| PRL spacing        | ⚠️ Approx | May need post-check               |
| LOD (SA/SB)        | ✅ Yes    | Guide constraint enforcement      |
| WPE (SCA/SCB/SCC)  | ✅ Yes    | Keepout zone blocking             |
| STI stress         | ✅ Yes    | SA/SB enclosure zones             |
| Thermal gradient   | ⚠️ Approx | Isotherm guide preference         |
| Coupling symmetry  | ✅ Yes    | Post-route PEX analysis           |

### Analog-Specific Constraints

| Constraint           | Enforced       | Method                             |
| -------------------- | -------------- | ---------------------------------- |
| Wire-length matching | ✅ Yes         | Length balancing step              |
| Via count matching   | ✅ Yes         | Via count balancing                |
| Same layer routing   | ✅ Yes         | Preferred layer constraint         |
| Shield wire spacing  | ✅ Yes         | Shield DRC check                   |
| Guard ring spacing   | ✅ Yes         | Guard ring DRC check               |
| Thermal isotherm     | ⚠️ Guide-based | Isotherm-following pathfinding     |
| STI stress avoidance | ✅ Yes         | LDE keepout zones                  |
| WPE avoidance        | ✅ Yes         | Well-edge exclusion zones          |
| CMP density          | ⚠️ Guide-based | Density balancing during routing   |
| Multi-pattern color  | ✅ Yes         | Color assignment consistency check |

---

## Part XX: Big-O Complexity (Enhanced)

### Per Expansion Step (Zero-DRC)

| Check             | Complexity                    |
| ----------------- | ----------------------------- |
| Basic spacing     | O(log n + k)                  |
| Via spacing       | O(log n + m)                  |
| Via enclosure     | O(1)                          |
| Width check       | O(1)                          |
| Shield DRC        | O(log n + k)                  |
| Guard ring DRC    | O(log n + k)                  |
| LOD check (SA/SB) | O(1) per guide constraint     |
| WPE check (SCA)   | O(1) per guide constraint     |
| Thermal cost      | O(1) thermal map query        |
| Coupling cost     | O(m) where m = neighbor count |

### Matched Routing

| Operation               | Complexity                     |
| ----------------------- | ------------------------------ |
| Steiner tree generation | O(p log p) where p = pin count |
| Wire-length balancing   | O(n) per net                   |
| Via count balancing     | O(n)                           |
| Parasitic estimation    | O(L) where L = route length    |
| Thermal isotherm query  | O(log g) where g = grid cells  |
| LDE cost computation    | O(1) per edge                  |
| Coupling delta          | O(m) where m = neighbors       |

### Full PEX Feedback Loop

| Phase              | Complexity                          |
| ------------------ | ----------------------------------- |
| RCX extraction     | O(n × m) where n = nets, m = shapes |
| Match analysis     | O(n) per group                      |
| Guide repair       | O(n × L)                            |
| Re-route           | O(L × (log n + k))                  |
| LDE guide update   | O(n) per floorplan change           |
| Thermal map update | O(A) where A = die area             |

---

## Part XXI: File Map (Enhanced)

### New Files in Spout

| File                              | Purpose                                                         |
| --------------------------------- | --------------------------------------------------------------- |
| `src/router/analog_router.zig`    | Main analog router, net group management, PEX feedback          |
| `src/router/matched_router.zig`   | Wire-length/via balancing, symmetric Steiner trees, CC patterns |
| `src/router/shield_router.zig`    | Shield wire generation, driven guards, Faraday cages            |
| `src/router/guard_ring.zig`       | Guard ring insertion, deep N-well, contact generation           |
| `src/router/steiner_tree.zig`     | Symmetric Steiner tree generation, mirroring, ABBA patterns     |
| `src/router/thermal_router.zig`   | Isotherm-aware routing, thermal map queries, hotspot avoidance  |
| `src/router/lde_router.zig`       | LOD/WPE-aware guide constraints, SA/SB keepout zones            |
| `src/router/capacitor_router.zig` | DAC capacitor array routing, unit element routing               |
| `src/router/resistor_router.zig`  | Matched resistor routing, Kelvin connections, star routing      |
| `src/characterize/pex_match.zig`  | Match analysis between nets, coupling delta computation         |
| `src/router/pex_feedback.zig`     | PEX-guided iterative repair, mismatch classification            |
| `src/characterize/thermal.zig`    | Thermal map generation, isotherm extraction, self-heating model |

### Modified Files

| File                            | Modification                                                      |
| ------------------------------- | ----------------------------------------------------------------- |
| `src/router/grid.zig`           | Add keepout zones for guard rings, shields, LOD, WPE              |
| `src/characterize/pex.zig`      | Add `extractNet()` for per-net extraction, add LOD/WPE extraction |
| `src/router/inline_drc.zig`     | Add shield/guard-ring/LOD/WPE-aware DRC checks                    |
| `src/router/cost_fn.zig`        | Add thermal, LDE, coupling, thermoelectric cost terms             |
| `src/floorplan/constraints.zig` | Add LDE constraints (SA/SB/SCA/SCB), thermal hotspots             |

### Integration with OpenROAD

| File                        | Purpose                                                      |
| --------------------------- | ------------------------------------------------------------ |
| `src/grt/GlobalRouter.cpp`  | Read analog net groups, generate guides with LDE constraints |
| `src/drt/src/dr/FlexDR.cpp` | Preserve analog guides, respect SA/SB constraints            |
| OpenROAD TCL                | New commands for analog net groups, thermal hotspots         |

---

## Part XXII: OpenROAD Integration (Enhanced)

### New TCL Commands

```tcl
# Create analog net groups
create_analog_net_group -name <name> -type DIFFERENTIAL|MATCHED|SHIELDED|KELVIN|RESISTOR|CAPACITOR \
    -nets <net_list> -tolerance <float> [-layer <layer>]

# Shield a net
set_net -shielded -shield_net <ground_net> -shield_layer <layer> <net>

# Driven guard (high-impedance nodes)
set_net -driven_guard -guard_net <shield_net> <net>

# Insert guard ring
insert_guard_ring -region <bbox> -type P_PLUS|N_PLUS|DEEP_NWELL|SUBSTRATE \
    -net <net> -width <float> -spacing <float> [-isolation_target <db>]

# Set route priority (higher = routed first)
set_net -analog_priority <int> <net>

# LDE constraints from floorplan
set_lde_constraints -device <id> -sa <um> -sb <um> [-sc <um>]

# Set thermal hotspots (for thermal-aware routing)
set_thermal_hotspots <list_of_bboxes> [-power_density <mw/um2>]
set_thermal_hotspots {{100 100 200 200} {500 500 600 600}}

# Analyze matching
report_pex_matching [-tolerance <float>]

# Kelvin (4-wire) connection
create_kelvin_connection -force_net <net> -sense_net <net> \
    -force_pins <pin_list> -sense_pins <pin_list>

# Star routing for reference distribution
set_net -star_routing -source <pin> <net>

# Multi-patterning color constraint
set_net -route_layer <layer> -color <1|2|3|4> <net>
```

### Guide Preservation

FlexDR must preserve guides for analog nets:

```cpp
// In FlexDR.cpp — modified guide handling
bool FlexDR::shouldRespectGuide(dbNet* net) {
    if (dbAnalogNetGroup* group = net->getAnalogGroup()) {
        return group->route_priority > 0;  // Analog nets use guides strictly
    }
    return false;  // Digital nets can modify guides
}
```

### LDE Guide Passthrough

Floorplan LDE constraints are communicated to the router via guide annotations:

```tcl
# Floorplanner emits these as guide properties
# FlexDR reads them and enforces SA/SB constraints during detailed routing
set_guide_property $guide -ldc_sa 1.0   ;# µm — min gate-to-STI source
set_guide_property $guide -ldc_sb 1.0   ;# µm — min gate-to-STI drain
set_guide_property $guide -ldc_sc 2.0   ;# µm — min distance from well edge
set_guide_property $guide -thermal_isotherm 1  ;# route along isotherm
```

---

## Part XXIII: Corner Cases (Enhanced)

### Corner Case 1: Differential Pair with Unequal Pin Count

**Problem:** net_p has 3 pins, net_n has 2 pins.

**Solution:** Use virtual pin at centroid for the shorter net:

```zig
if (pins_p.len != pins_n.len) {
    const extra_pin = computeCentroid(pins_p);
    pins_n = pins_n ++ .{extra_pin};
}
```

### Corner Case 2: Shield Wire DRC Conflict

**Problem:** Shield wire on layer M3 conflicts with existing M3 route.

**Solution:** Skip shielding for conflicting segments. Shield continuity is less important than DRC.

### Corner Case 3: Guard Ring Overlaps Existing Metal

**Problem:** Guard ring region overlaps existing VSS routing.

**Solution:** Use stitch-in guard rings — create gap where overlap exists, add contacts on both sides of gap.

### Corner Case 4: Via Balancing Creates DRC Violation

**Problem:** Adding dummy via to balance count creates spacing violation.

**Solution:** Check DRC before adding via. If violation, try alternative silent segment. If none found, allow via count delta > 1. Log as warning in MatchReport.

### Corner Case 5: Thermal Gradient During Routing

**Problem:** Routing changes thermal map (self-heating), invalidating isotherm assumptions.

**Solution:** Iterative approach — route → estimate self-heating → adjust thermal map → re-route. Self-heating is proportional to current density, which changes when wire widths change during balancing.

### Corner Case 6: Multi-Patterning Color Conflict in Matched Nets

**Problem:** Matched nets assigned different colors on a double-patterned layer due to congestion.

**Solution:** Route matched nets on non-multi-patterned layers when available. If forced to use DP layer, reserve color assignment for matched groups before global routing.

### Corner Case 7: Anti-Parallel Current Flow in Cross-Coupled Layout

**Problem:** Matched devices have cross-connections causing anti-parallel current flow, generating Seebeck thermoelectric offset.

**Solution:** Detect cross-coupled topology, add compensating serpentine to the lower-Seebeck net to cancel the thermoelectric EMF differential.

### Corner Case 8: Deep N-Well Cannot Fit Between Guard Rings

**Problem:** Multiple analog blocks require deep N-well isolation but die area is insufficient for nested ring structure.

**Solution:** Share deep N-well between adjacent analog blocks. The router merges deep N-well regions and places a single combined ring with taps on all sides. Isolation may degrade slightly but area is saved.

### Corner Case 9: FinFET Fin Quantization Causes Width Mismatch

**Problem:** Two matched devices need 10 fins and 10.5 fins respectively (matched pair with slight W difference), but fin count must be integer.

**Solution:** Quantize to 10 fins for both, accept slight overdrive mismatch. Router flags this in the LDE report so the designer can decide whether to accept or adjust floorplan.

### Corner Case 10: Kelvin Connection Over Same Net Route

**Problem:** Force and sense nets are routed on the same physical path, defeating the purpose of Kelvin connection.

**Solution:** Kelvin routing explicitly prevents segment sharing between force and sense paths. The router uses a different layer for sense routing or adds physical separation. A design rule check verifies zero segment overlap between force and sense nets.

---

## Part XXIV: Summary — What Gets Zero DRC, LVS, and PEX Optimization

### Guarantees

| Property              | Guarantee       | Method                                             |
| --------------------- | --------------- | -------------------------------------------------- |
| **Zero DRC**          | By construction | Embedded DRC in FlexDR maze expansion              |
| **LVS correct**       | By construction | Keepout zones, net ownership, atomic vias          |
| **Matched R**         | By construction | Wire-length + width balancing                      |
| **Matched C**         | By construction | Same layer, length balancing, coupling rebalancing |
| **Matched via count** | By construction | Via count balancing step                           |
| **Shielded nets**     | Guaranteed      | Shield router generates shields                    |
| **Guard rings**       | Guaranteed      | Guard ring inserter places rings                   |
| **Kelvin separation** | Guaranteed      | Separate force/sense routing enforced              |
| **LDE constraints**   | By construction | SA/SB/SCA keepout zones                            |
| **Same color (DP)**   | Guaranteed      | Color reservation before global routing            |

### What's Verified, Not Guaranteed

| Property            | Verification           | Repair                      |
| ------------------- | ---------------------- | --------------------------- |
| Thermal isotherm    | Post-route thermal sim | Move guides, re-route       |
| STI stress          | LDE extraction         | Adjust SA/SB guides         |
| Coupling symmetry   | PEX match analysis     | Adjust layer assignment     |
| Density             | DRC density check      | Fill step after routing     |
| Self-heating        | Thermal simulation     | Adjust wire widths, reroute |
| FinFET quantization | Floorplan verification | Quantize to nearest fin     |

---

## Appendix A: Analytic Formulas Quick Reference

### Pelgrom Mismatch

$$\sigma(\Delta V_T) = \frac{A_{VT}}{\sqrt{WL}}$$

$$\sigma\!\left(\frac{\Delta \beta}{\beta}\right) = \frac{A_\beta}{\sqrt{WL}}$$

### Drain Current Mismatch

$$\sigma^2\!\left(\frac{\Delta I_D}{I_D}\right) = \frac{1}{WL}\left[A_\beta^2 + \frac{4 A_{VT}^2}{(V_{GS}-V_T)^2}\right]$$

### Thermal $V_{th}$ Shift

$$V_{th}(T) = V_{th0} - \delta(T - T_0), \quad \delta \approx 1\text{–}4 \text{ mV/°C}$$

### LOD Inverse Stress

$$\text{Inv}_{sa} = \frac{1}{SA + 0.5 \cdot L_{\text{drawn}}}$$

### Coupling Capacitance (parallel plates)

$$C = \frac{\epsilon \cdot A}{d} = \frac{\epsilon_r \epsilon_0 \cdot W \cdot L}{t_{\text{ox}}}$$

### Wire Resistance

$$R = \frac{\rho \cdot L}{W \cdot t} = R_s \cdot \frac{L}{W}$$

where $R_s = \rho / t$ is sheet resistance (Ω/□).

### Differential Capacitance Target

$$C_{\text{diff}} = \max(C_1, \ldots, C_n) - \min(C_1, \ldots, C_n) \to 0$$

---

## Appendix B: Abbreviation Glossary

| Abbr        | Term                                         |
| ----------- | -------------------------------------------- |
| ABBA        | Interdigitation pattern: A-B-B-A             |
| CC          | Common Centroid                              |
| CMP         | Chemical Mechanical Polishing                |
| DRC         | Design Rule Check                            |
| DP          | Double Patterning                            |
| GLE         | Gate Line End Effect                         |
| GAA         | Gate-All-Around (nanosheet FET)              |
| LDE         | Layout-Dependent Effects                     |
| LER         | Line-Edge Roughness                          |
| LOD         | Length of Diffusion (SA/SB effect)           |
| LVS         | Layout vs. Schematic                         |
| MBE         | Metal Boundary Effect                        |
| NDE         | Neighboring Diffusion Effect                 |
| PEX         | Parasitic Extraction                         |
| PSE         | Poly Spacing Effect                          |
| RDF         | Random Dopant Fluctuation                    |
| SA/SB       | Source-side/Drain-side distance to STI (LOD) |
| SCA/SCB/SCC | Well Proximity Effect basis functions        |
| STI         | Shallow Trench Isolation                     |
| WPE         | Well Proximity Effect                        |

---

## Research Sources

- ARCHITECTURE_ZERO_DRC_ROUTER.md — embedded DRC constraints in maze expansion
- ARCHITECTURE_OPENROAD.md — OpenROAD routing architecture
- RESEARCH_TECHNIQUES.md — analog layout techniques (Pelgrom, LOD, STI stress, guard rings, shielding, common centroid, FinFET, GAA, CMP)
- RESEARCH_OPENROAD_ANALOG_ROUTING.md — OpenROAD analog routing gap analysis
- Pelgrom et al., "Matching properties of MOS transistors," IEEE JSSC 1989
- Hastings, "The Art of Analog Layout" — matching hierarchy, guard rings, dummy devices
- Boser, Berkeley EE240B — dispersion principle, common-centroid patterns
- BSIM4/BSIM-CMG documentation — LOD, WPE, STI stress equations
