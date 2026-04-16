# Analog IC Layout Techniques: Complete Technical Reference

This document reproduces and expands the complete content of `RESEARCH_TECHNIQUES.md`, covering every technique for analog IC layout with mathematical formulations, physical justification, and explicit mapping to Spout's subsystems.

---

## Architecture Diagram: Research Techniques → Spout Subsystems

<svg viewBox="0 0 1200 720" xmlns="http://www.w3.org/2000/svg" font-family="'Inter', 'Segoe UI', sans-serif">
  <!-- Background -->
  <rect width="1200" height="720" fill="#060C18"/>

  <!-- Title -->
  <text x="600" y="36" fill="#B8D0E8" font-size="18" font-weight="700" text-anchor="middle">Research Techniques → Spout Subsystems</text>

  <!-- ── Subsystem boxes (right column) ─────────────────────────────────── -->
  <!-- Constraint Extractor -->
  <rect x="840" y="60" width="200" height="52" rx="6" fill="#0D1E36" stroke="#14263E" stroke-width="1.5"/>
  <text x="940" y="82" fill="#00C4E8" font-size="13" font-weight="700" text-anchor="middle">Constraint Extractor</text>
  <text x="940" y="99" fill="#3E5E80" font-size="11" text-anchor="middle">src/constraint/</text>

  <!-- SA Placer -->
  <rect x="840" y="130" width="200" height="52" rx="6" fill="#0D1E36" stroke="#14263E" stroke-width="1.5"/>
  <text x="940" y="152" fill="#1E88E5" font-size="13" font-weight="700" text-anchor="middle">SA Placer</text>
  <text x="940" y="169" fill="#3E5E80" font-size="11" text-anchor="middle">src/placer/</text>

  <!-- Router -->
  <rect x="840" y="200" width="200" height="52" rx="6" fill="#0D1E36" stroke="#14263E" stroke-width="1.5"/>
  <text x="940" y="222" fill="#43A047" font-size="13" font-weight="700" text-anchor="middle">Router</text>
  <text x="940" y="239" fill="#3E5E80" font-size="11" text-anchor="middle">src/router/</text>

  <!-- DRC Engine -->
  <rect x="840" y="270" width="200" height="52" rx="6" fill="#0D1E36" stroke="#14263E" stroke-width="1.5"/>
  <text x="940" y="292" fill="#EF5350" font-size="13" font-weight="700" text-anchor="middle">DRC Engine</text>
  <text x="940" y="309" fill="#3E5E80" font-size="11" text-anchor="middle">router/inline_drc.zig</text>

  <!-- PEX -->
  <rect x="840" y="340" width="200" height="52" rx="6" fill="#0D1E36" stroke="#14263E" stroke-width="1.5"/>
  <text x="940" y="362" fill="#AB47BC" font-size="13" font-weight="700" text-anchor="middle">PEX / Signoff</text>
  <text x="940" y="379" fill="#3E5E80" font-size="11" text-anchor="middle">python/tools.py</text>

  <!-- Liberty -->
  <rect x="840" y="410" width="200" height="52" rx="6" fill="#0D1E36" stroke="#14263E" stroke-width="1.5"/>
  <text x="940" y="432" fill="#FB8C00" font-size="13" font-weight="700" text-anchor="middle">Liberty / Char.</text>
  <text x="940" y="449" fill="#3E5E80" font-size="11" text-anchor="middle">src/liberty/ src/characterize/</text>

  <!-- GDSII Export -->
  <rect x="840" y="480" width="200" height="52" rx="6" fill="#0D1E36" stroke="#14263E" stroke-width="1.5"/>
  <text x="940" y="502" fill="#00C4E8" font-size="13" font-weight="700" text-anchor="middle">GDSII Export</text>
  <text x="940" y="519" fill="#3E5E80" font-size="11" text-anchor="middle">src/export/gdsii.zig</text>

  <!-- ── Technique labels (left/center column) ────────────────────────── -->
  <!-- Pelgrom Mismatch Model -->
  <rect x="30" y="64" width="220" height="36" rx="4" fill="#0A1825" stroke="#14263E"/>
  <text x="140" y="87" fill="#B8D0E8" font-size="12" text-anchor="middle">Pelgrom Mismatch Model</text>

  <!-- Common Centroid -->
  <rect x="30" y="110" width="220" height="36" rx="4" fill="#0A1825" stroke="#14263E"/>
  <text x="140" y="133" fill="#B8D0E8" font-size="12" text-anchor="middle">Common Centroid / ABBA</text>

  <!-- Interdigitation -->
  <rect x="30" y="156" width="220" height="36" rx="4" fill="#0A1825" stroke="#14263E"/>
  <text x="140" y="179" fill="#B8D0E8" font-size="12" text-anchor="middle">Interdigitation</text>

  <!-- Multi-finger devices -->
  <rect x="30" y="202" width="220" height="36" rx="4" fill="#0A1825" stroke="#14263E"/>
  <text x="140" y="225" fill="#B8D0E8" font-size="12" text-anchor="middle">Multi-finger Devices</text>

  <!-- Dummy Devices -->
  <rect x="30" y="248" width="220" height="36" rx="4" fill="#0A1825" stroke="#14263E"/>
  <text x="140" y="271" fill="#B8D0E8" font-size="12" text-anchor="middle">Dummy Devices</text>

  <!-- Guard Rings -->
  <rect x="30" y="294" width="220" height="36" rx="4" fill="#0A1825" stroke="#14263E"/>
  <text x="140" y="317" fill="#B8D0E8" font-size="12" text-anchor="middle">Guard Rings</text>

  <!-- STI Stress / LDE -->
  <rect x="30" y="340" width="220" height="36" rx="4" fill="#0A1825" stroke="#14263E"/>
  <text x="140" y="363" fill="#B8D0E8" font-size="12" text-anchor="middle">STI Stress / LDE (LOD, WPE)</text>

  <!-- Simulated Annealing -->
  <rect x="30" y="386" width="220" height="36" rx="4" fill="#0A1825" stroke="#14263E"/>
  <text x="140" y="409" fill="#B8D0E8" font-size="12" text-anchor="middle">Simulated Annealing</text>

  <!-- RUDY Routing Density -->
  <rect x="30" y="432" width="220" height="36" rx="4" fill="#0A1825" stroke="#14263E"/>
  <text x="140" y="455" fill="#B8D0E8" font-size="12" text-anchor="middle">RUDY Routing Density</text>

  <!-- Lee / Maze Routing -->
  <rect x="30" y="478" width="220" height="36" rx="4" fill="#0A1825" stroke="#14263E"/>
  <text x="140" y="501" fill="#B8D0E8" font-size="12" text-anchor="middle">Lee / Maze Routing</text>

  <!-- Magic tile DRC -->
  <rect x="30" y="524" width="220" height="36" rx="4" fill="#0A1825" stroke="#14263E"/>
  <text x="140" y="547" fill="#B8D0E8" font-size="12" text-anchor="middle">Magic Tile DRC Model</text>

  <!-- Analog ML Placement -->
  <rect x="30" y="570" width="220" height="36" rx="4" fill="#0A1825" stroke="#14263E"/>
  <text x="140" y="593" fill="#B8D0E8" font-size="12" text-anchor="middle">ML-Based Placement (ALIGN)</text>

  <!-- Parasitic Symmetry -->
  <rect x="30" y="616" width="220" height="36" rx="4" fill="#0A1825" stroke="#14263E"/>
  <text x="140" y="639" fill="#B8D0E8" font-size="12" text-anchor="middle">Parasitic Symmetry Routing</text>

  <!-- ── Connector lines ──────────────────────────────────────────────── -->
  <!-- Pelgrom → Constraint Extractor -->
  <line x1="250" y1="82" x2="840" y2="86" stroke="#00C4E8" stroke-width="1" stroke-dasharray="4,3" opacity="0.6"/>
  <!-- Pelgrom → SA Placer -->
  <line x1="250" y1="82" x2="840" y2="156" stroke="#1E88E5" stroke-width="1" stroke-dasharray="4,3" opacity="0.4"/>

  <!-- Common Centroid → Constraint Extractor -->
  <line x1="250" y1="128" x2="840" y2="86" stroke="#00C4E8" stroke-width="1.5" stroke-dasharray="4,3" opacity="0.7"/>
  <!-- Common Centroid → SA Placer -->
  <line x1="250" y1="128" x2="840" y2="156" stroke="#1E88E5" stroke-width="1.5" stroke-dasharray="4,3" opacity="0.7"/>

  <!-- Interdigitation → SA Placer -->
  <line x1="250" y1="174" x2="840" y2="156" stroke="#1E88E5" stroke-width="1.5" stroke-dasharray="4,3" opacity="0.7"/>

  <!-- Multi-finger → SA Placer -->
  <line x1="250" y1="220" x2="840" y2="156" stroke="#1E88E5" stroke-width="1" stroke-dasharray="4,3" opacity="0.5"/>
  <!-- Multi-finger → GDSII Export -->
  <line x1="250" y1="220" x2="840" y2="502" stroke="#00C4E8" stroke-width="1" stroke-dasharray="4,3" opacity="0.3"/>

  <!-- Dummy Devices → SA Placer -->
  <line x1="250" y1="266" x2="840" y2="156" stroke="#1E88E5" stroke-width="1" stroke-dasharray="4,3" opacity="0.5"/>
  <!-- Dummy Devices → GDSII Export -->
  <line x1="250" y1="266" x2="840" y2="502" stroke="#00C4E8" stroke-width="1" stroke-dasharray="4,3" opacity="0.3"/>

  <!-- Guard Rings → GDSII Export -->
  <line x1="250" y1="312" x2="840" y2="502" stroke="#00C4E8" stroke-width="1.5" stroke-dasharray="4,3" opacity="0.7"/>
  <!-- Guard Rings → Router -->
  <line x1="250" y1="312" x2="840" y2="226" stroke="#43A047" stroke-width="1" stroke-dasharray="4,3" opacity="0.4"/>

  <!-- LDE → Constraint Extractor -->
  <line x1="250" y1="358" x2="840" y2="86" stroke="#00C4E8" stroke-width="1.5" stroke-dasharray="4,3" opacity="0.6"/>
  <!-- LDE → SA Placer -->
  <line x1="250" y1="358" x2="840" y2="156" stroke="#1E88E5" stroke-width="1" stroke-dasharray="4,3" opacity="0.4"/>

  <!-- Simulated Annealing → SA Placer -->
  <line x1="250" y1="404" x2="840" y2="156" stroke="#1E88E5" stroke-width="2" opacity="0.9"/>

  <!-- RUDY → SA Placer -->
  <line x1="250" y1="450" x2="840" y2="156" stroke="#1E88E5" stroke-width="1.5" stroke-dasharray="4,3" opacity="0.7"/>

  <!-- Lee / Maze → Router -->
  <line x1="250" y1="496" x2="840" y2="226" stroke="#43A047" stroke-width="2" opacity="0.9"/>

  <!-- Magic DRC → DRC Engine -->
  <line x1="250" y1="542" x2="840" y2="296" stroke="#EF5350" stroke-width="1.5" stroke-dasharray="4,3" opacity="0.7"/>
  <!-- Magic DRC → PEX -->
  <line x1="250" y1="542" x2="840" y2="366" stroke="#AB47BC" stroke-width="1.5" stroke-dasharray="4,3" opacity="0.6"/>

  <!-- ML Placement → SA Placer -->
  <line x1="250" y1="588" x2="840" y2="156" stroke="#1E88E5" stroke-width="1" stroke-dasharray="4,3" opacity="0.4"/>
  <!-- ML Placement → Constraint Extractor -->
  <line x1="250" y1="588" x2="840" y2="86" stroke="#00C4E8" stroke-width="1" stroke-dasharray="4,3" opacity="0.4"/>

  <!-- Parasitic Symmetry → Router -->
  <line x1="250" y1="634" x2="840" y2="226" stroke="#43A047" stroke-width="1.5" stroke-dasharray="4,3" opacity="0.6"/>
  <!-- Parasitic Symmetry → PEX -->
  <line x1="250" y1="634" x2="840" y2="366" stroke="#AB47BC" stroke-width="1" stroke-dasharray="4,3" opacity="0.4"/>

  <!-- Legend -->
  <rect x="290" y="660" width="620" height="46" rx="4" fill="#0A1825" stroke="#14263E"/>
  <line x1="310" y1="683" x2="360" y2="683" stroke="#B8D0E8" stroke-width="2"/>
  <text x="370" y="687" fill="#B8D0E8" font-size="11">Solid = primary driver</text>
  <line x1="480" y1="683" x2="530" y2="683" stroke="#B8D0E8" stroke-width="1.5" stroke-dasharray="4,3"/>
  <text x="540" y="687" fill="#B8D0E8" font-size="11">Dashed = informs / influences</text>
  <text x="600" y="703" fill="#3E5E80" font-size="10" text-anchor="middle">Colors match target subsystem</text>
</svg>

---

## 1. Root Causes of Mismatch in Analog ICs

Mismatch in analog circuits arises from both stochastic and deterministic mechanisms spanning multiple physical domains.

### 1.1 Random Mismatch

**Random Dopant Fluctuation (RDF)** — the dominant random mismatch source in bulk CMOS. The MOSFET channel contains a discrete number of dopant atoms under the gate. For doping concentration $N_A$, width $W$, length $L$, depletion depth $t_{depl}$:

$$N_{dopants} = N_A \cdot W \cdot L \cdot t_{depl}$$

Statistical fluctuation follows Poisson statistics with $\sigma_N = \sqrt{N_{dopants}}$:

$$\sigma(V_T) = \frac{q \cdot t_{ox}}{\epsilon_{ox}} \cdot \sqrt{\frac{N_A \cdot t_{depl}}{W \cdot L}}$$

This is the physical origin of Pelgrom's $1/\sqrt{WL}$ dependence. Keyes (1975) first studied this; Pelgrom et al. (1989) formalized it. The physically derived $A_{VT,local}$ explains roughly **60%** of measured local variation.

**Line-Edge Roughness (LER)** — stochastic photoresist exposure and polysilicon grain boundaries. At sub-45 nm nodes, LER contributions to $\sigma(V_{th})$ reach **50–80%** of the RDF contribution at 13 nm.

**Oxide Thickness Variation** — causes fluctuations in $C_{ox}$ and hence $V_T$ and $\beta$. In HKMG technologies, **work function variation (WFV)** from metal gate granularity has replaced oxide thickness variation; TiN gate grain boundaries cause local work function differences on the order of hundreds of millivolts.

### 1.2 Systematic Mismatch

Deterministic gradients across the die:

- **Temperature gradients**: $V_T$ has a temperature coefficient of approximately **−1 to −2 mV/°C** — a 1 °C gradient across a matched pair produces millivolts of $V_{th}$ mismatch.
- **Doping concentration gradients**: Variations in implant dose and energy across the wafer and die.
- **Oxide thickness gradients**: Slow spatial variation in $t_{ox}$ across the die, typically well-modeled as linear.
- **Mechanical stress gradients**: Die attach, wire bonding, packaging, and proximity to die edges.

Pelgrom's full model including systematic terms:

$$\sigma^2(\Delta P) = \frac{A_P^2}{WL} + S_P^2 \cdot D^2$$

where $S_P$ is the spatial gradient coefficient and $D$ is the inter-device distance.

### 1.3 Layout-Dependent Effects (LDE)

Three dominant mechanisms create deterministic, geometry-dependent parameter shifts:

**STI (Shallow Trench Isolation) stress** — SiO₂ fill (α ≈ 0.5 × 10⁻⁶/°C) vs silicon (α ≈ 2.6 × 10⁻⁶/°C). STI stress can exceed **750 MPa** and shift $I_{dsat}$ by **20–30%** and $V_{th}$ by **>10 mV**.

**Well Proximity Effect (WPE)** — ion scattering off photoresist sidewalls during well implantation, creating enhanced doping near well edges that decays over approximately **1 µm**. $\Delta V_{th}$ can reach **tens of millivolts** at sub-100 nm spacing.

**Length of Diffusion (LOD)** — equivalent to SA/SB effect. Distance from gate to STI edge modulates channel stress. Captured in BSIM4 via SA, SB, and SD instance parameters.

**Spout relevance**: These effects inform the SA placer's `w_symmetry` and `w_matching` cost weights, and the constraint extractor's pattern recognition (differential pairs, current mirrors, cascodes all benefit from equal LOD/WPE treatment).

### 1.4 Parasitic Mismatch

RC mismatch from routing asymmetry. With metal sheet resistance of **50–100 mΩ/□**, 10 squares of routing produce ~1 Ω, yielding **~1 mV/mA** of IR drop. Spout's router attempts parasitic symmetry by routing matched pairs with equal-length paths.

### 1.5 Environmental Effects

Substrate coupling from digital switching. Supply bounce through bond wire inductance (~1 nH/mm). Guard rings (generated by `src/export/gdsii.zig`) mitigate substrate coupling.

---

## 2. The Pelgrom Mismatch Model

**Reference**: M. J. M. Pelgrom, A. C. J. Duinmaijer, A. P. G. Welbers, "Matching properties of MOS transistors," _IEEE JSSC_, vol. 24, no. 5, pp. 1433–1440, Oct. 1989.

### Core Equations

**Threshold voltage mismatch:**
$$\boxed{\sigma(\Delta V_T) = \frac{A_{VT}}{\sqrt{W \cdot L}}}$$

**Current factor mismatch:**
$$\boxed{\sigma\!\left(\frac{\Delta\beta}{\beta}\right) = \frac{A_{\beta}}{\sqrt{W \cdot L}}}$$

**Full model with distance-dependent systematic term:**
$$\sigma^2(\Delta V_T) = \frac{A_{VT}^2}{W \cdot L} + S_{VT}^2 \cdot D^2$$

### Drain Current Mismatch

From square-law saturation $I_D = \frac{\beta}{2}(V_{GS} - V_T)^2$:

$$\boxed{\sigma^2\!\left(\frac{\Delta I_D}{I_D}\right) = \frac{A_{\beta}^2}{WL} + \left(\frac{g_m}{I_D}\right)^2 \cdot \frac{A_{VT}^2}{WL}}$$

### Differential Pair Input-Referred Offset

$$\sigma^2(\Delta V_{os}) = \frac{A_{VT}^2}{WL} + \frac{(V_{GS}-V_T)^2}{4} \cdot \frac{A_{\beta}^2}{WL}$$

**Design insight:** Differential pairs benefit from low overdrive (large $g_m/I_D$). Current mirrors benefit from high overdrive.

### Pelgrom Coefficients Across Technology Nodes

| Process node | $A_{VT}$ NMOS (mV·µm) | $A_{VT}$ PMOS (mV·µm) | $A_{\beta}$ (%·µm) |
| ------------ | --------------------- | --------------------- | ------------------ |
| 500 nm       | 15–20                 | 20–30                 | ~2.0               |
| 180 nm       | ~5                    | 7–8                   | 1–2                |
| 130 nm       | ~3.5                  | ~3.5                  | 1.5–2              |
| 65 nm        | 2.5–3.5               | 3.5–4.5               | ~1.5               |
| 28 nm        | 1.5–2.5               | 2–3                   | 1–1.5              |
| 14 nm FinFET | 1.0–1.5               | —                     | —                  |

Sky130 (180 nm node): $A_{VT,NMOS} \approx 5$ mV·µm. This directly determines minimum device sizes for a given matching specification in Spout's target PDK.

### Layout Constraints from Mismatch Requirements

For required matching accuracy $\sigma_{spec}$:

$$W \cdot L \geq \left(\frac{A_{VT}}{\sigma_{spec}(\Delta V_T)}\right)^2$$

For six-sigma yield: spec ≥ 6σ.

### Limitations at Advanced Nodes

The Pelgrom model breaks down in several regimes: non-Gaussian tails at small device areas, halo-implanted devices creating non-monotonic Pelgrom plots, LDE dominance below 65 nm, sub-threshold operation exponential sensitivity, and new variability sources (metal gate granularity, fin width/height variation, nanosheet thickness).

---

## 3. The Matching Hierarchy

### Level 1 — Basic: Same Device, Size, Orientation

Same type (both NMOS or both PMOS), identical dimensions ($W$, $L$, number of fingers), identical crystallographic orientation. Different orientations can introduce **~5% error** due to silicon crystal anisotropy and tilted implant angles. Device ratios implemented using unit elements rather than dimension scaling.

### Level 2 — Intermediate: Proximity, Environment, Dummies

Close proximity to minimize gradient exposure. Identical surroundings: same distance to wells, same STI boundaries, symmetric guard rings. Dummy devices at array edges equalize etch rates, lithographic proximity, and mechanical stress.

### Level 3 — High Precision: Interdigitation, Thermal Matching, Routing Symmetry

Interdigitation (ABBA pattern) averages out 1D process gradients. Matched signals routed with identical length, width, and via count. Critical matched devices kept away from hot spots ($dV_{th}/dT \approx -2$ mV/K). Serpentine resistors: even number of segments with half oriented in each direction.

### Level 4 — Extreme Precision: Common Centroid, Stress-Aware, Current-Flow Symmetry

**Common-centroid** placement positions device segments so geometric centroids of all matched devices coincide, with symmetry in both X and Y axes — cancels 2D gradients to first order. Key principles: **coincidence** (centroids match), **symmetry** (mirror about center), **dispersion** (fewer contiguous same-device runs = better), and **compactness** (approximately square arrays).

**Spout implementation:** The SA placer cost function includes `w_symmetry` (default 2.0) and `w_matching` (default 1.5) weights. The constraint extractor auto-identifies differential pairs and current mirrors from netlist topology, feeding symmetry and matching constraints into the placer.

---

## 4. Symmetry in Analog Layout

### Four Levels of Symmetry

**Geometric symmetry** — physical layout is mirror-symmetric. Necessary but not sufficient.

**Electrical symmetry (parasitic symmetry)** — actual parasitic R, C, L values are matched: $C_1 = C_2$, $R_1 = R_2$. Requires identical metal layers, identical via counts, identical coupling environments.

**Thermal symmetry** — matched devices at the same temperature. Power dissipation blocks >50 mW create local gradients. The SA placer's `w_thermal` cost weight (default 0.0, configurable) supports thermal-aware placement.

**Stress/process symmetry** — identical mechanical stress from packaging, CMP, STI, and metal layers.

### Current Flow Symmetry and Thermoelectric Effects

The **Seebeck effect** at junctions of dissimilar conductors generates EMF proportional to temperature difference — typically **0.2–1.4 mV/°C**. Anti-parallel current flow causes these voltages to cancel. For serpentine resistors, both contacts should reside close together.

### Impact on Circuit Performance

Symmetry directly determines: **offset voltage** (dominated by $\Delta V_{th}$ and parasitic asymmetry), **CMRR** (device or parasitic asymmetry converts common-mode to differential), **flicker noise**, and **PSRR**.

---

## 5. Dummy Devices

### Physics of Edge Effects

**Edge lithography bias** — interior gates flanked by identical features create uniform diffraction patterns. Edge gates lack this periodicity.

**STI stress gradient** — edge devices see STI on one side and active silicon on the other, causing asymmetric stress that shifts $V_{th}$ by **>10 mV** and $I_{dsat}$ by **15–20%** for NMOS.

**Implant shadowing** — tilted ion implantation (~7°) causes photoresist edges to shadow certain device regions; WPE adds scattered ions from resist sidewalls.

### Implementation Rules

Dummy devices must have the same size, orientation, spacing, well membership, and finger width as active devices. Continuous diffusion (shared OD) between dummy and active gates is preferred. Dummies must be placed at **both ends** of every matched device array.

### Dummy Gate Connections

NMOS dummies: gate, drain, source, and body all tied to **VSS**. PMOS dummies: all terminals tied to **VDD**. Alternative: gate tied to source ($V_{GS} = 0$). Dummies must be **back-annotated into the schematic** for LVS verification.

**Spout implementation:** `src/export/gdsii.zig` generates dummy poly gates at array ends. The LVS check via `tools.py:run_klayout_lvs()` verifies these are correct in the extracted netlist.

---

## 6. Multi-Finger Devices

### Gate Resistance Reduction

Polysilicon gate as distributed RC transmission line. For a single finger of width $W_f$, gate length $L$, double-sided gate contacts:

$$R_{g,\text{double}} = \frac{R_{sh} \cdot W_f}{12 \cdot L}$$

For a multi-finger device with $n_f$ fingers and total width $W = n_f \cdot W_f$:

$$R_g = \frac{R_{sh} \cdot W}{12 \cdot L \cdot n_f^2}$$

The $n_f^2$ scaling enables RF operation, reduces thermal noise ($4kTR_g$), and improves bandwidth.

### Source/Drain Sharing and Capacitance Reduction

Adjacent fingers share source/drain diffusion regions. For $n_f$ fingers, total source/drain diffusion area is approximately **halved** compared to $n_f$ separate single-finger devices, reducing $C_{db}$, $C_{sb}$ by ~50% for $n_f \geq 4$.

**Spout implementation:** `DeviceParams.fingers` field tracks finger count. Device bounding-box computation in `lib.zig:computeDeviceDimensions()` accounts for multi-finger layouts. The `mult` parameter tracks device multiplicity (separate instances for 2D placement).

### Enabling Interdigitation and Common Centroid

Multi-finger decomposition is the **prerequisite** for all advanced matching techniques. **Fingers** (shared diffusion) are optimal for 1D interdigitation; **multipliers** enable true 2D common-centroid placement.

---

## 7. Interdigitated Layout

### Gradient Cancellation

For $n$ fingers each at equally spaced positions $x_k = k \cdot d$ along one axis, with a linear gradient $P(x) = P_0 + \alpha x$:

$$\bar{P}_A = P_0 + \alpha \cdot \frac{1}{n}\sum_{k \in A} x_k, \quad \bar{P}_B = P_0 + \alpha \cdot \frac{1}{n}\sum_{k \in B} x_k$$

For symmetric interdigitation (ABBA endpoints), $\sum_{k \in A} x_k = \sum_{k \in B} x_k$ — **perfect cancellation of linear gradients along the finger direction**.

### Limitations

Interdigitation is inherently **one-dimensional**: it cancels gradients along the direction of interleaving but provides no protection against perpendicular gradients. For 2D gradient cancellation, full common-centroid is required.

---

## 8. Common-Centroid Layout

### Mathematical Framework

Process parameter variation at position $(x, y)$ modeled as 2D polynomial:

$$P(x,y) = P_0 + g_{1,0}\,x + g_{0,1}\,y + g_{2,0}\,x^2 + g_{1,1}\,xy + g_{0,2}\,y^2 + \cdots$$

For device A composed of $m$ unit cells at positions $(x_{Ai}, y_{Ai})$:

$$P_A = m\bigl(g_{1,0}\,\bar{x}_A + g_{0,1}\,\bar{y}_A + P_0\bigr) + \text{higher orders}$$

**If centroids coincide** ($\bar{x}_A = \bar{x}_B$, $\bar{y}_A = \bar{y}_B$), then $P_A - P_B = 0$ for any linear gradient.

### ABBA Pattern

Four unit cells at positions $-3d/2$, $-d/2$, $+d/2$, $+3d/2$:

$$\bar{x}_A = \frac{-3d/2 + 3d/2}{2} = 0, \quad \bar{x}_B = \frac{-d/2 + d/2}{2} = 0$$

Both centroids coincide — exact cancellation of all linear gradients.

### ABBABAAB and Higher-Order Patterns

The $n$th-order central symmetrical pattern is constructed recursively. ABBABAAB (8 cells) cancels gradients up to second order. Each $n$th-order pattern uses $2^n$ unit cells per device.

The **dispersion principle** (Boser, Berkeley EE240B): ABABBABA is preferable to ABBAABBA because fewer contiguous runs of the same device produce better averaging of higher-order spatial variation.

### 2D Common Centroid (Cross-Coupled Quad)

$$\begin{bmatrix} A & B \\ B & A \end{bmatrix}$$

Each device's centroid lies at the geometric center in both x and y. The cross-term $exy$ does **not** cancel for simple 2×2 (residual mismatch = $2ed^2$). A 2×4 (ABBA/BAAB) or 4×4 checkerboard pattern is needed to cancel the cross-term. George Erdi pioneered this in the µA725 op-amp (~1971).

**Spout implementation:** The `w_symmetry` cost in the SA placer promotes common-centroid-like arrangements for detected matched pairs.

---

## 9. Cross-Quad Layout

The cross-quad extends the 2×2 common centroid with **four-way symmetry**: mirror symmetry about both axes plus 180° rotational symmetry. Linear gradients cancel exactly; pure quadratic terms $cx^2 + dy^2$ cancel. The cross-term $exy$ produces residual mismatch of $2ed^2$ in a simple 2×2.

Used in **precision voltage references**, **ADC reference ladders**, and **high-resolution DAC current sources** where matching exceeds 12 bits.

---

## 10. Matrix and Array Layouts

### 2D Grid Patterns

For large device matching (DAC current source arrays, capacitor banks), devices distributed in 2D grids where **every device type** appears in every row and column — analogous to a Latin square.

### DAC Capacitor Arrays

**Binary-weighted** arrays: capacitors in powers of two ($C$, $2C$, $4C$, ...) — poor matching at MSBs. **Unit-element (unary)** approaches: all values from identical unit capacitors $C_u$ — enables common-centroid placement.

Placement algorithms: **spiral** (cells spiraling outward from center with reflective CC symmetry), **chessboard** (MSB capacitors on alternating grid positions — maximum dispersion but higher routing cost), and **block chessboard** (hybrid). Optimal array aspect ratio: close to **1:1 (square)**.

### Segmentation

Large devices decomposed into identical unit segments. Target value of $N \times C_u$ uses $N$ unit elements placed in CC arrangement. Dummy elements at array periphery equalize fringe capacitance and etch environment.

---

## 11. Routing Techniques for Matched Circuits

### Parasitic Symmetry Requirements

**Parasitic symmetry — not geometric symmetry — determines matching.** Requirements: **equal wire length**, **same metal layers** (different layers have different sheet resistance — M1–M4 ~80 mΩ/□ vs M5 ~20 mΩ/□), **same shielding environment**, **same via count** (each via adds 1–10 Ω), and **equal coupling capacitance** to aggressors.

The PARSY router introduced the differential capacitance metric: $C_{\text{diff}} = \max(C_1, \ldots, C_n) - \min(C_1, \ldots, C_n)$, which must approach zero.

**Spout implementation:** The router in `src/router/maze.zig` and `src/router/detailed.zig` handles routing. The `w_parasitic` cost weight (default 0.2) in the SA placer penalizes placement configurations that would produce asymmetric routing. The `w_rudy` weight (default 0.3) uses the RUDY routing density estimator to prefer placements with lower expected routing congestion.

### Star Routing

Each load receives its bias from a dedicated, non-shared path to a single reference point. Essential for distributing reference voltages and bias currents. Kelvin (4-wire) connections separate current-carrying and voltage-sensing paths.

### How Routing Destroys Matching

Even 1 mV/mA of IR drop through routing resistance can destroy matching. The practical rule: if symmetry is broken at the routing level, no amount of device-level matching can compensate.

---

## 12. Guard Rings

### Substrate Coupling Physics

The substrate acts as a distributed 3D resistive-capacitive network. Coupling occurs through **capacitive** paths (source/drain depletion capacitances), **resistive** paths (injected substrate current via body effect — $g_{mb}/g_m \approx 0.1$–$0.3$), and **minority carrier injection** (forward-biased junctions inject electrons that diffuse tens of micrometers).

### Guard Ring Mechanism

**N+ guard rings** in p-substrate form reverse-biased junctions (connected to VDD) that collect electron minority carriers. **P+ guard rings** (connected to VSS) stabilize local substrate potential. A conventional guard ring achieves approximately **9 dB** of isolation improvement. Localized guard ring methodologies reduce peak-to-peak substrate noise by **72%**.

### Latch-up Prevention

Guard rings reduce $R_{\text{N-well}}$ and $R_{\text{P-sub}}$, increasing the holding current needed to sustain the parasitic PNPN thyristor.

### Deep N-Well Isolation

Deep N-well creates a buried N-type layer beneath the P-well, providing **20+ dB improvement** at low frequencies.

**Spout implementation:** Guard rings are generated automatically by `src/export/gdsii.zig` around every MOSFET. The `ring_spacing` and `ring_width` PDK parameters in `layout_if.PdkConfig` control guard ring geometry. The device bounding-box computation in `computeDeviceDimensions()` includes `ring_ext = pdk_cfg.guard_ring_spacing + pdk_cfg.guard_ring_width` to ensure the placer allocates sufficient space.

---

## 13. Shielding

Grounded metal shielding intercepts capacitively coupled noise. A floating shield is **ineffective** — effective coupling is $(C_1 \cdot C_2)/(C_1 + C_2)$.

Shield grounding must match the signal reference — **never use digital ground for analog shields**. For high-impedance nodes (op-amp inputs, sense amplifier inputs), shields driven at the **same potential** as the sensitive node (driven guard) prevent surface leakage and minimize capacitive loading.

Via spacing for on-chip Faraday cages: less than $\lambda/20$ of the highest frequency of concern.

---

## 14. STI Stress Effects

### Physics and Mobility Modification

STI fill material (SiO₂) thermal expansion coefficient is approximately **5× lower** than silicon. During high-temperature processing, this mismatch induces compressive stress exceeding **750 MPa** at the STI-silicon boundary.

**NMOS**: Compressive stress along the channel direction **degrades** electron mobility by raising the energy of the $\Delta_2$ valleys relative to $\Delta_4$. NMOS $I_{dsat}$ **decreases** by up to **6%** at maximum stress.

**PMOS**: Compressive stress **enhances** hole mobility by splitting heavy-hole and light-hole bands. PMOS $I_{dsat}$ **increases** by up to **9%**.

### Quantitative Impact

Measured $V_{th}$ shifts: NMOS up to **+10 mV** (14 mV peak-to-peak) in 180 nm; PMOS up to **+27 mV**. In 65 nm technology, STI-induced variation can reach **45.3%** in output voltage.

### BSIM4 Model

Instance parameters **SA** (gate-to-STI distance on source side) and **SB** (drain side):

$$V_{TH0} = V_{TH0,\text{orig}} + K_{\text{stress,vth0}} \cdot \left(\frac{1}{SA + L/2} + \frac{1}{SB + L/2} - \frac{1}{SA_{\text{ref}} + L/2} - \frac{1}{SB_{\text{ref}} + L/2}\right)$$

$$\mu_{\text{eff}} = \frac{1 + \rho_{\mu}(SA, SB)}{1 + \rho_{\mu}(SA_{\text{ref}}, SB_{\text{ref}})} \cdot \mu_{\text{eff},0}$$

### Solutions

Place matched transistors at **equal SA and SB distances**. Insert **dummy poly gates** at array ends. Use **large SA/SB values** (≥3 µm from STI).

---

## 15. Well Proximity Effect (WPE)

### Physics

During ion implantation, ions impinging on photoresist scatter near the resist edge, creating enhanced well doping extending approximately **1 µm** from the well boundary.

### Impact

$\Delta V_{th}$ reaches **several tens of mV** at 0.1 µm spacing. At 65 nm, WPE causes up to **10% delay increase**. Combined with LOD, $V_{th}$ shifts can exceed **100 mV** for devices very close to well edges.

### BSIM4 WPE Model

$$V_{TH0} = V_{TH0,\text{noWPE}} + \text{KVTH0WE} \cdot (\text{SCA} + \text{WEB} \cdot \text{SCB} + \text{WEC} \cdot \text{SCC})$$

$$\mu = \mu_{\text{noWPE}} \cdot \left[1 + \text{KU0WE} \cdot (\text{SCA} + \text{WEB} \cdot \text{SCB} + \text{WEC} \cdot \text{SCC})\right]$$

### Solutions

Place matched devices at **equal distance from well edges**. Use **large wells** to increase SC distances. Ensure **symmetric well geometry** around matched pairs.

---

## 16. Length of Diffusion (LOD) Effect

### Physics and BSIM4 Equations

$\text{LOD} = SA + L_g + SB$. Inverse-distance stress functions:

$$\text{Inv}_{sa} = \frac{1}{SA + 0.5 \cdot L_{\text{drawn}}}, \quad \text{Inv}_{sb} = \frac{1}{SB + 0.5 \cdot L_{\text{drawn}}}$$

For multi-finger devices with $n_f$ fingers, effective stress is averaged:

$$\text{Inv}_{sa,\text{eff}} = \frac{1}{n_f} \sum_{i=1}^{n_f} \frac{1}{SA + SD \cdot (i-1) + 0.5L}$$

### Solutions

Ensure **equal SA, SB, and SD** for all transistors in matched pairs. Insert **dummy poly gates** at ends of active regions.

---

## 17. Passive Device Matching

### Capacitor Matching

$$\sigma\!\left(\frac{\Delta C}{C}\right) = \frac{A_C}{\sqrt{\text{Area}}}$$

**MOM capacitors**: interdigitated metal combs where lateral coupling between wires dominates. Fringe and line-end capacitance contribute ~10%+ of total. **MIM capacitors**: best matching (record-low random mismatch of **20 ppm** with cross-coupled CC test structures) but require extra mask step. **MOS capacitors**: worst matching due to bias-dependent C-V characteristics.

### Resistor Matching

Current crowding at contacts and bends. A right-angle bend has effective resistance of approximately **0.56 squares**. Total resistance:

$$R_{\text{total}} = R_{\text{body}} + 2R_{\text{contact}}$$

| Resistor type     | Sheet R (typical) | TCR          | Matching quality    |
| ----------------- | ----------------- | ------------ | ------------------- |
| Polysilicon       | 50–200+ Ω/□       | Low–moderate | Best among passives |
| Diffusion (P+/N+) | 50–150 Ω/□        | Higher       | Moderate            |
| N-well            | 1–5 kΩ/□          | High         | Poor                |
| Metal             | 0.02–0.1 Ω/□      | ~3900 ppm/°C | Moderate            |

**Spout implementation:** `DeviceType` includes `res_poly`, `res_diff_n`, `res_diff_p`, `res_well_n`, `res_well_p`, `res_metal`. Bounding-box computation uses $w \times l$ with default 2×8 µm fallback (4:1 aspect ratio).

---

## 18. Thermal Effects on Matching

### Temperature Gradient Mechanisms

$$V_{th}(T) = V_{th0} - \delta(T - T_0), \quad \delta \approx 1\text{–}4 \text{ mV/°C}$$

A **1 °C gradient** across matched devices causes **1–4 mV** of $V_{th}$ mismatch. Mobility: $\mu \propto T^{-2.3}$.

### Self-Heating at Advanced Nodes

At 3 nm, self-heating can cause **≥50 °C** temperature rise. Thermal resistance reaches ~34,000 K/W with thermal time constants of ~17 ns.

**Spout implementation:** The SA placer has a `w_thermal` cost weight (default 0.0, disabled by default). When enabled, it penalizes placement configurations where matched devices are close to high-power devices.

---

## 19. Substrate Coupling and Noise Isolation

On epitaxial substrates (~0.01 Ω·cm bulk), coupling approaches a **constant non-zero value** independent of distance. On lightly-doped substrates (~1–20 Ω·cm), distance and guard rings are effective.

Digital circuits inject noise through: **ground bounce** ($V = L \cdot di/dt$, often dominant), **capacitive coupling** (junction displacement currents), and **minority carrier injection**.

Solutions in order of increasing effectiveness: physical separation, P+ guard rings (~9 dB), deep N-well (**20–30+ dB** at low frequencies), triple-well, separate power domains.

---

## 20. Reference Distribution

Metal sheet resistance of 50–100 mΩ/□ creates voltage errors proportional to current × routing resistance. For reference circuits: $V_{\text{ref}} = I_{\text{out}} \times (R_{\text{load}} + R_{\text{parasitic}})$.

**Star routing:** each circuit receives a dedicated, non-shared path. **Kelvin connections:** separate current-carrying and voltage-sensing paths. VDD and VSS routing to matched circuits must use the same metal layer, width, length, and via count.

---

## 21. Density Equalization and CMP Effects

CMP removes material at rates dependent on local pattern density. **Dishing** in low-density areas, **erosion** in high-density areas. Uncontrolled density can produce **767 Å** of post-CMP topography variation, reducible to **152 Å** with dummy fill.

**Matching-aware fill:** exclusion zones (keep fill away from sensitive devices), symmetric fill (identical patterns around matched pairs), and interconnect widening.

---

## 22. Common Failure Modes

- **Perfect centroid with bad routing**: CC placement but asymmetric interconnect nullifies matching.
- **Symmetric geometry with asymmetric current flow**: stress-induced mobility anisotropy and thermoelectric offsets.
- **Missing dummies**: edge devices with different etch rates, mechanical stress, LOD values, fringe capacitance.
- **Ignoring LDE**: catastrophic at advanced nodes; LDE can dominate over random mismatch entirely at 28 nm and below.
- **Poor substrate isolation**: switching noise coupling through substrate.

---

## 23. Circuit-Specific Technique Selection

**Differential pairs**: Level 4 matching — common-centroid (ABBA or cross-coupled quad) for input transistors, symmetric routing with equal parasitics, guard rings, placement away from digital and power blocks.

**Current mirrors**: interdigitation or common centroid with equal LOD (identical SA/SB via dummy poly gates). Large-$L$ devices reduce channel-length modulation mismatch.

**Bandgap references**: common-centroid BJTs (e.g., 3×3 grid for 8:1 emitter area ratio), matched PTAT and CTAT resistors in interdigitated layout with equal TCR.

**ADC/DAC arrays**: unit-element approaches with common-centroid placement (spiral, chessboard, or block chessboard algorithms), dummy elements, parasitic-symmetric routing.

**PLL charge pumps**: matched UP/DOWN current sources with symmetric routing from PFD outputs, cascode mirrors, placement of bandgap/bias references far from digital PFD and divider.

---

## 24. Modern Challenges at Advanced Nodes

### LDE Dominance and Nonlinear Gradients

At nodes ≤40 nm, **LDE-induced systematic mismatch exceeds random mismatch**. Ignoring LDE can produce **up to 140% error** in series resistance and **25% error** in total capacitance. Standard CC placement cancels only linear gradients; increasingly nonlinear variation profiles at advanced nodes require higher-order patterns, more dispersed layouts, and exhaustive post-layout LDE extraction.

### FinFET-Specific Challenges

Transistor width is **quantized** to integer multiples of fin pitch — analog designers lose continuous $W/L$ tuning. Supply voltage drops to **0.7–0.9 V** at 7 nm/5 nm, severely limiting headroom for cascode structures. New LDE: **Gate Line End Effect (GLE)** (6.3% $I_{dsat}$ shift for nFET), **Poly Spacing Effect (PSE)**, **Neighboring Diffusion Effect (NDE)**, **Metal Boundary Effect (MBE)** — all modeled in BSIM-CMG.

### GAA Nanosheet Challenges

GAA/nanosheet FETs at ≤3 nm quantize width by nanosheet count. Self-heating more severe. CFET stacks NMOS on PMOS, introducing new matching and thermal coupling challenges.

### Parasitic Dominance

At 7 nm and below, parasitic resistance and capacitance **dominate device behavior**. Even a single extra via creates meaningful mismatch. RC-extracted simulation is mandatory for all analog designs.

### ML-Based Layout Automation

**ALIGN** (Analog Layout, Intelligently Generated from Netlists) — DARPA IDEA program, University of Minnesota / Texas A&M / Intel. Uses **Graph Convolutional Networks (GCN)** for subcircuit identification and constraint annotation. Supports LDE-aware common-centroid placement. Other frameworks: **MAGICAL** (UT Austin), **BAG** (UC Berkeley).

**Spout relevance:** Spout's constraint extractor (`src/constraint/extract.zig`) performs the same subcircuit identification as ALIGN's GCN stage but using rule-based pattern matching rather than neural networks. The ML write-back FFI (`spout_set_device_embeddings`, `spout_add_constraints_from_ml`) exists to support future GCN-based augmentation.

---

## 25. The Master Mismatch Model

### Total Mismatch Decomposition

$$\sigma^2_{\text{total}} = \sigma^2_{\text{random}} + \sigma^2_{\text{gradient}} + \sigma^2_{\text{LDE}} + \sigma^2_{\text{parasitic}} + \sigma^2_{\text{thermal}} + \sigma^2_{\text{electrical}}$$

Each term is addressed by specific layout techniques. Spout's SA cost function directly targets three of these six components through its cost weights:

| Mismatch Component   | SA Cost Weight     | Spout Mechanism                                |
| -------------------- | ------------------ | ---------------------------------------------- |
| Random               | `w_symmetry`       | Promotes common-centroid-like placement         |
| Gradient             | `w_symmetry`       | Matched device centroid coincidence             |
| LDE                  | `w_matching`       | Equal SA/SB via proximity constraints          |
| Parasitic            | `w_parasitic`      | Minimize routing asymmetry                     |
| Thermal              | `w_thermal`        | Distance from power devices                    |
| Electrical           | `w_embed_similarity`| ML embedding similarity (future)              |

The HPWL cost (`w_hpwl`) and RUDY density cost (`w_rudy`) are routing-focused metrics that reduce overall parasitic capacitance through shorter, more predictable routing.

---

## Key References

1. **Pelgrom, M. J. M., Duinmaijer, A. C. J., Welbers, A. P. G.** "Matching properties of MOS transistors." _IEEE JSSC_, vol. 24, no. 5, pp. 1433–1440, Oct. 1989. — Foundational mismatch model, defines $A_{VT}$ and $A_\beta$.

2. **Hastings, A.** _The Art of Analog Layout_. Prentice Hall, 2001. — Matching hierarchy, dummy devices, guard rings. Directly referenced in the four-level matching framework.

3. **Razavi, B.** _Design of Analog CMOS Integrated Circuits_. McGraw-Hill, Chapters 18–19. — Differential pair matching, current mirror layout.

4. **Carusone, T., Johns, D., Martin, K.** _Analog Integrated Circuit Design_. Wiley. — Matching hierarchy framework used in Section 3.

5. **Boser, B.** Berkeley EE240B lectures. — Dispersion principle, guard ring design rules, density fill advice.

6. **George Erdi** µA725 op-amp (~1971) — Pioneer of 2D cross-coupled common-centroid placement.

7. **ALIGN** (University of Minnesota / Texas A&M / Intel, DARPA IDEA program) — ML-based analog layout automation, GCN-based constraint extraction.

8. **MAGICAL** (UT Austin) — Analog layout automation framework.

9. **BAG** (UC Berkeley) — Generator-based analog layout.

10. **BSIM4 model documentation** — SA, SB, SCA, SCB, SCC parameters for LDE modeling.

11. **Ousterhout, J. K.** "Corner stitching: a data-structuring technique for VLSI layout tools." _IEEE Trans. CAD_, vol. 3, no. 1, 1984. — Data structure underlying Magic's DRC engine.
