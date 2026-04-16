# Analog Placer Architecture & Gap Analysis

Cross-reference of `src/placer/` against analog layout techniques documented in `RESEARCH_TECHNIQUES.md` (Pelgrom mismatch model, six-component mismatch budget, matching hierarchy Levels 1-4).

---

## Current Inventory

### Cost Function (cost.zig) — 6 terms

| Term | Weight | What it does |
|------|--------|-------------|
| HPWL | `w_hpwl` | Half-perimeter wire length, power nets excluded |
| Area | `w_area` | Bounding-box area of all device positions |
| Symmetry | `w_symmetry` | X-axis mirror: `|x_a + x_b - 2*axis| + |y_a - y_b|` (L1 or L2) |
| Matching | `w_matching` | Parabolic well at min-separation distance: `(dist - min_sep)²` |
| RUDY | `w_rudy` | Congestion overflow from RUDY grid |
| Overlap | `w_overlap` | AABB overlap area between all device pairs |

### SA Engine (sa.zig)

- **Moves**: translate, swap, mirror_swap, macro_translate, macro_transform
- **Schedule**: two-level κ·N with three-phase cooling (α=0.80/0.97/0.80)
- **Adaptive ρ(T)**: perturbation range scales with temperature
- **Reheating**: acceptance-ratio triggered (r < 2% → T *= 3)
- **Hierarchical**: two-phase macro placement (unit-cell SA → super-device SA → stamp)

### Constraints (types.zig ConstraintType enum)

```
symmetry  = 0   ← evaluated in cost.zig
matching  = 1   ← evaluated in cost.zig
proximity = 2   ← DEAD: never checked in any cost term
isolation = 3   ← DEAD: never checked in any cost term
```

### RUDY Grid (rudy.zig)

- Rectangular uniform wire density estimator (Spindler & Johannes, DATE 2007)
- Incremental update on device move
- Overflow metric: Σ max(0, demand - capacity)

---

## Gap Analysis

Mapped against the six orthogonal mismatch components from RESEARCH_TECHNIQUES.md Section 25:

```
σ²_total = σ²_random + σ²_gradient + σ²_LDE + σ²_parasitic + σ²_thermal + σ²_electrical
```

### Gap 0: Dead Constraint Types

`proximity` and `isolation` exist in the enum but produce **zero cost**. `computeSymmetry` only checks `.symmetry`, `computeMatching` only checks `.matching`. Two of four constraint types are wasted.

**Required**:
- `proximity`: penalize distance beyond threshold (decoupling caps near sensitive circuits, bias devices near mirrors)
- `isolation`: penalize closeness below threshold (analog-digital separation, substrate noise — RESEARCH_TECHNIQUES.md Section 19)

**Effort**: Small. Add two loops in `cost.zig` mirroring the existing patterns.

### Gap 1: No Common-Centroid (targets σ²_gradient)

RESEARCH_TECHNIQUES.md Section 8 — mandatory for differential pairs, bandgap BJTs, DAC arrays. The current symmetry constraint is single-axis mirror only. Common-centroid requires centroid coincidence in **both X and Y** across N unit cells.

**What's missing**:
- Y-axis symmetry (no `axis_y` field — can't enforce horizontal mirror)
- 2D centroid coincidence: `centroid_A == centroid_B` for device groups, not just pair mirroring
- ABBA / ABBABAAB pattern generation
- Cross-quad placement (AB/BA 2×2 grid — George Erdi µA725 pattern)
- Dispersion metric (fewer contiguous same-device runs = better gradient averaging)

**Mathematical formulation** (from RESEARCH_TECHNIQUES.md Section 8):

For device A composed of m unit cells at positions (x_Ai, y_Ai):
```
P_A - P_B = m * [g_10 * (x̄_A - x̄_B) + g_01 * (ȳ_A - ȳ_B)]
```
If centroids coincide (x̄_A = x̄_B, ȳ_A = ȳ_B), mismatch = 0 for any linear gradient.

**Suggested constraint type**: `common_centroid` with `device_group_a: []u32, device_group_b: []u32`
**Suggested cost**: `w_cc * (|x̄_a - x̄_b|² + |ȳ_a - ȳ_b|²)`

**Effort**: Medium.

### Gap 2: No LDE Awareness (targets σ²_LDE)

RESEARCH_TECHNIQUES.md Sections 14-16 — at ≤65nm, LDE-induced systematic mismatch **exceeds random mismatch**. Three mechanisms with zero placer coverage:

**STI stress** (Section 14): Compressive stress from SiO₂ fill shifts Idsat by 20-30% and Vth by >10 mV. Captured via BSIM4 SA/SB parameters (gate-to-STI distance on source/drain sides). Matched devices need equal SA/SB.

**WPE** (Section 15): Ion scattering off resist sidewalls during well implant. ΔVth reaches tens of mV at well edges, decays over ~1 µm. Captured via SCA/SCB/SCC parameters.

**LOD** (Section 16): Same phenomenon as STI stress viewed from diffusion geometry. LOD = SA + Lg + SB. Multi-finger averaging: Inv_sa_eff = (1/nf) * Σ 1/(SA + SD*(i-1) + 0.5L).

**Suggested cost term**:
```
w_lde * Σ_matched_pairs [(SA_a - SA_b)² + (SB_a - SB_b)²]
```
Requires knowing STI boundaries — derivable from device placement + dummy positions, or accepted as input geometry.

**Effort**: Medium. Needs device-level SA/SB computation from surrounding geometry.

### Gap 3: No Dummy Device Modeling (targets σ²_LDE + σ²_gradient)

RESEARCH_TECHNIQUES.md Section 5 — edge devices see 10+ mV Vth shifts and 15-20% Idsat shifts without dummies. Three physical mechanisms: edge lithography bias, STI stress gradient at array edges, implant shadowing.

**What's missing**:
- No dummy device concept (no `is_dummy` flag)
- No edge-effect penalty for matched devices at array boundaries
- No dummy insertion or validation
- No enforcement that dummies match active device dimensions/spacing/orientation

**Implementation rules from research**: same size, same orientation, same spacing, same well, same finger width, placed at both ends of every matched array, gate/source/drain/body tied (not floating).

**Effort**: Medium.

### Gap 4: No Device Orientation Tracking (targets σ²_random + σ²_LDE)

RESEARCH_TECHNIQUES.md Section 3 (Level 1 matching) — different orientations cause ~5% error from silicon crystal anisotropy and tilted implant angles.

Current devices are `(x, y, w, h)` — no rotation/mirror state.

**What's missing**:
- Orientation enum per device (N, S, FN, FS, E, W, FE, FW — standard 8 DEF orientations)
- Constraint that matched devices share orientation
- SA move to flip/rotate single devices
- Cost penalty for orientation mismatch between constrained pairs

**Effort**: Medium.

### Gap 5: No Thermal Symmetry (targets σ²_thermal)

RESEARCH_TECHNIQUES.md Section 18 — Vth temperature coefficient ≈ -1 to -4 mV/°C. A 1°C gradient across matched devices → 1-4 mV mismatch.

**What's missing**:
- No heat source identification
- No isotherm placement constraint
- No thermal asymmetry cost term

**Suggested cost term** (given known heat source positions H_k with power P_k):
```
T(pos) ≈ Σ_k P_k / |pos - H_k|²
w_thermal * Σ_matched_pairs |T(pos_a) - T(pos_b)|²
```

**Effort**: Small (if heat sources provided as input).

### Gap 6: No Interdigitation Constraint (targets σ²_gradient)

RESEARCH_TECHNIQUES.md Section 7 — ABABAB finger interleaving for 1D gradient cancellation. Between full common-centroid and simple proximity matching.

For n fingers each at positions x_k = k·d with symmetric interdigitation:
```
Σ_{k∈A} x_k = Σ_{k∈B} x_k → P̄_A = P̄_B (perfect 1D cancellation)
```

**What's missing**: constraint forcing alternating placement of unit cells along one axis. The `mirror_swap` move is a pair operation, not an N-cell interleave.

**Effort**: Medium.

### Gap 7: No Parasitic Routing Symmetry (targets σ²_parasitic)

RESEARCH_TECHNIQUES.md Section 11 — "if symmetry is broken at routing level, no amount of device-level matching can compensate." Even 1 mV/mA of IR drop through routing resistance destroys matching.

RUDY estimates congestion but not **differential parasitic balance** between matched signal paths. Requirements: equal wire length, same metal layers, same via count, equal coupling capacitance.

**Suggested approach**: estimate routing length from placement (Manhattan distance from each device to net centroid) and add cost for length imbalance:
```
w_parasitic * Σ_matched_pairs (L_route_a - L_route_b)²
```

**Effort**: Medium.

### Gap 8: No Guard Ring / Well Geometry Awareness (targets σ²_LDE + σ²_electrical)

RESEARCH_TECHNIQUES.md Section 12 — guard rings provide ~9 dB isolation. Deep N-well gives 20+ dB. Complete enclosures required ("a fence, not one fencepost").

RESEARCH_TECHNIQUES.md Section 15 — WPE causes ΔVth of tens of mV near well edges.

**What's missing**:
- Well boundary geometry
- Guard ring placement / completeness check
- Device-to-well-edge distance in cost function

**Effort**: Large.

---

## Symmetry Constraint is X-Only

Current `Constraint.axis_x` supports only vertical-axis mirroring. Analog layout commonly needs:

| Pattern | Current support | Needed for |
|---------|----------------|------------|
| Vertical-axis mirror | Yes (`axis_x`) | Diff pairs side-by-side |
| Horizontal-axis mirror | **No** (`axis_y` missing) | Stacked pairs |
| Both-axis mirror | **No** | True common-centroid |
| 180° rotational | **No** | Cross-quad |

---

## Priority-Ranked Improvements

| Pri | Improvement | Targets | Effort | Impact |
|-----|------------|---------|--------|--------|
| P0 | Wire up `proximity` + `isolation` cost terms | σ²_electrical | Small | Enables basic separation/closeness control |
| P0 | Add Y-axis symmetry (`axis_y` field) | σ²_gradient | Small | Handles horizontal mirror pairs |
| P1 | Common-centroid constraint + cost term | σ²_gradient | Medium | Mandatory for diff pairs, bandgaps, DACs |
| P1 | Device orientation tracking + constraint | σ²_random, σ²_LDE | Medium | Prevents ~5% mismatch from orientation |
| P1 | LDE-aware cost term (SA/SB equalization) | σ²_LDE | Medium | Dominant mismatch source at ≤65nm |
| P2 | Dummy device modeling + edge-effect penalty | σ²_LDE, σ²_gradient | Medium | Edge-effect compensation |
| P2 | Thermal symmetry cost term | σ²_thermal | Small | Prevents mV-level thermal mismatch |
| P2 | Interdigitation constraint (ABAB pattern) | σ²_gradient | Medium | 1D gradient cancellation for mirrors |
| P3 | Parasitic routing balance estimation | σ²_parasitic | Medium | Catches wiring-destroys-matching failure |
| P3 | Guard ring / well geometry awareness | σ²_LDE, σ²_electrical | Large | WPE compensation, substrate isolation |

---

## Mismatch Budget Coverage Map

| Mismatch Component | Current Coverage | Key Gap |
|-------------------|-----------------|---------|
| σ²_random (RDF, LER, oxide) | Indirect — device sizing is external | None at placer level (correct: sizing is pre-placement) |
| σ²_gradient (temp, doping, stress) | Partial — X-axis symmetry only | No Y-axis, no common-centroid, no interdigitation |
| σ²_LDE (STI, WPE, LOD) | **None** | No SA/SB, no SCA/SCB/SCC, no dummy modeling |
| σ²_parasitic (routing R/C) | Congestion only (RUDY) | No differential parasitic balance |
| σ²_thermal | **None** | No heat source model, no isotherm constraint |
| σ²_electrical (ΔVds, IR drop) | **None** | No supply routing model, no isolation cost |

---

## File Structure Reference

```
src/placer/
├── cost.zig    — 6-term cost function (HPWL, area, symmetry, matching, RUDY, overlap)
├── rudy.zig    — RUDY congestion grid with incremental update
├── sa.zig      — SA engine: moves, schedule, reheating, hierarchical macro placement
├── tests.zig   — Integration tests for cost + SA + RUDY
└── ARCH.md     — This file
```
