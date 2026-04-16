# Analog Router Implementation Plan

## Phased Rollout

Build order follows data dependency — each phase produces tables consumed by the next. No phase requires code from a later phase. Every phase is independently testable.

```
Phase 1: Core Data Tables + ID Types        (no deps)
Phase 2: Spatial Index (R-tree / uniform grid) (Phase 1)
Phase 3: Analog Net Group Database           (Phase 1)
Phase 4: Matched Router                      (Phase 1-3)
Phase 5: Shield Router                       (Phase 1-3)
Phase 6: Guard Ring Inserter                 (Phase 1-3)
Phase 7: Thermal Router                      (Phase 1-3)
Phase 8: LDE Router                          (Phase 1-3)
Phase 9: PEX Feedback Loop                   (Phase 1-4)
Phase 10: Thread Pool + Parallel Dispatch    (Phase 1-9)
Phase 11: Integration + Signoff              (all)
```

---

## Phase 1: Core Data Tables + ID Types

**Goal:** Define all SoA tables, new index types, and the `AnalogRouteDB` that owns them.

**New files:**

| File | Lines (est.) | Purpose |
|------|-------------|---------|
| `src/router/analog_types.zig` | ~200 | New ID types, enums, small structs |
| `src/router/analog_db.zig` | ~400 | `AnalogRouteDB` — owns all SoA tables |
| `src/router/spatial_grid.zig` | ~500 | Uniform spatial grid for DRC/coupling queries |

**Modified files:**

| File | Change |
|------|--------|
| `src/core/types.zig` | Add `AnalogGroupIdx`, `ShieldIdx`, `GuardRingIdx`, `SteinerNodeIdx` |
| `src/router/lib.zig` | Export new analog modules |

**Deliverables:**
- All struct layouts defined, `@sizeOf` compile-time assertions
- `AnalogRouteDB.init()` / `deinit()` with arena allocation
- Round-trip tests for all new ID types
- Cache line utilization documented in `DOD_DATA_LAYOUT.md`

**Exit criteria:** `zig build test` passes, zero leaks under `std.testing.allocator`.

---

## Phase 2: Spatial Index

**Goal:** Replace O(n) linear scan in `inline_drc.zig` with O(log n + k) uniform grid.

**New files:**

| File | Lines (est.) | Purpose |
|------|-------------|---------|
| `src/router/spatial_grid.zig` | ~500 | 2D uniform grid with per-cell segment lists |

**Key decisions:**
- Uniform grid (not R-tree) — cell count known at init from die bbox + pitch. O(1) cell lookup.
- Cell size = 2 x max(min_spacing) across all layers. Guarantees spacing queries touch at most 9 cells.
- Per-cell: `std.ArrayListUnmanaged(u32)` of segment indices into `AnalogRouteDB.segments`.
- Rebuild is O(n) — acceptable after rip-up. No incremental maintenance during routing.

**Modified files:**

| File | Change |
|------|--------|
| `src/router/inline_drc.zig` | Add `SpatialDrcChecker` that wraps spatial grid |

**Exit criteria:** Spacing query benchmarks show <100ns per query at 10K segments.

---

## Phase 3: Analog Net Group Database

**Goal:** Parse analog constraints, build group tables, validate device matching.

**New files:**

| File | Lines (est.) | Purpose |
|------|-------------|---------|
| `src/router/analog_groups.zig` | ~350 | `AnalogGroupDB` — SoA table of net groups |

**Data flow:**
```
User constraints (JSON/TCL) → AnalogGroupDB.addGroup() → validates device types match
                                                       → validates device sizes within tolerance
                                                       → assigns route priority
```

**Modified files:**

| File | Change |
|------|--------|
| `src/router/analog_db.zig` | Integrate `AnalogGroupDB` ownership |

**Exit criteria:** Can create differential, matched, shielded, kelvin, resistor, capacitor groups. Rejects invalid groups (type mismatch, size mismatch). Round-trip serialization test.

---

## Phase 4: Matched Router

**Goal:** Symmetric Steiner trees, wire-length balancing, via count balancing, parasitic symmetry cost function.

**New files:**

| File | Lines (est.) | Purpose |
|------|-------------|---------|
| `src/router/matched_router.zig` | ~600 | Core matched routing engine |
| `src/router/symmetric_steiner.zig` | ~300 | Symmetric Steiner tree generation |

**Algorithm:**
1. Generate Steiner tree for reference net (reuse existing `steiner.zig`)
2. Mirror tree around group centroid axis for paired net
3. Route both nets with A* using `MatchedRoutingCost`
4. Balance wire lengths (add jogs on silent segments)
5. Balance via counts (add dummy vias where DRC-clean)

**Modified files:**

| File | Change |
|------|--------|
| `src/router/astar.zig` | Add `MatchedCostFn` callback parameter to `findPath()` |
| `src/router/steiner.zig` | Add `mirror()` and `centroidAxis()` |

**Exit criteria:** Differential pair routes with <1% length mismatch. Via count delta <= 1. Same layer for both nets.

---

## Phase 5: Shield Router

**Goal:** Generate shield wires on adjacent layers, driven guards for high-Z nodes.

**New files:**

| File | Lines (est.) | Purpose |
|------|-------------|---------|
| `src/router/shield_router.zig` | ~300 | Shield wire generation + DRC check |

**Algorithm:**
1. For each shielded net group, get route segments
2. For each segment, compute shield rect on adjacent layer
3. DRC check shield rect against spatial index
4. Skip conflicting segments (shield continuity < DRC)
5. Connect shield wires to shield net (ground) with vias

**Exit criteria:** Shield wires generated. DRC clean. No shorts between shield and signal.

---

## Phase 6: Guard Ring Inserter

**Goal:** Place P+/N+/deep-N-well guard rings around analog blocks.

**New files:**

| File | Lines (est.) | Purpose |
|------|-------------|---------|
| `src/router/guard_ring.zig` | ~400 | Guard ring placement + contact generation |

**Algorithm:**
1. Compute ring bbox from analog block bbox + spacing
2. Generate donut shape (outer - inner rect)
3. Place contacts at configurable pitch
4. Register with spatial index and DRC checker
5. Handle stitch-in for existing metal overlaps

**Edge cases:**
- Ring overlaps existing VSS metal → stitch-in gap
- Adjacent analog blocks → merge deep N-well regions
- Ring too close to die edge → clip and warn

**Exit criteria:** Complete enclosure verified. Contact density meets isolation target. DRC clean.

---

## Phase 7: Thermal Router

**Goal:** Isotherm-aware routing, thermal map queries, hotspot avoidance.

**New files:**

| File | Lines (est.) | Purpose |
|------|-------------|---------|
| `src/router/thermal.zig` | ~300 | Thermal map + isotherm extraction |

**Data:**
- Thermal map = 2D grid of f32 temperatures, cell size ~10 um
- Populated from user-supplied hotspot locations + simple diffusion model
- `queryTemp(x, y) -> f32` is O(1) grid lookup

**Algorithm:**
1. Build thermal map from hotspot list
2. Extract isotherms as contour polygons
3. During matched routing, add thermal cost term: `|T_a - T_b| * weight`
4. Prefer routing both nets along same isotherm

**Exit criteria:** Matched nets have thermal gradient < tolerance. Routing avoids hotspots.

---

## Phase 8: LDE Router

**Goal:** LOD/WPE-aware guide constraints, SA/SB keepout zones.

**New files:**

| File | Lines (est.) | Purpose |
|------|-------------|---------|
| `src/router/lde.zig` | ~250 | LDE cost function + keepout zone generation |

**Algorithm:**
1. Receive LDE constraints from floorplan (SA, SB, SCA per device)
2. Generate keepout zones around device pins
3. Add LDE cost term to A* expansion: penalize SA/SB asymmetry between matched devices
4. During PEX feedback, extract LDE parameters and compare

**Exit criteria:** SA/SB difference between matched devices < tolerance. WPE exclusion zones enforced.

---

## Phase 9: PEX Feedback Loop

**Goal:** Extract per-net R, C, via count. Compare within matched groups. Repair if needed.

**Modified files:**

| File | Change |
|------|--------|
| `src/characterize/pex.zig` | Add `extractNet()` for per-net extraction |
| `src/router/matched_router.zig` | Add `repairFromPexReport()` |

**New files:**

| File | Lines (est.) | Purpose |
|------|-------------|---------|
| `src/router/pex_feedback.zig` | ~300 | Match analysis + repair dispatch |

**Algorithm:**
```
loop (max_iterations = 5):
    route all analog groups
    extract PEX per-net
    compute MatchReport per group
    if all pass tolerance → break
    for each failing metric:
        R mismatch → adjust widths
        C mismatch → adjust layers
        length mismatch → add jogs
        via mismatch → add dummy vias
        coupling mismatch → rebalance layer assignment
    re-route affected groups
```

**Exit criteria:** All matched groups pass tolerance after <= 5 iterations. Reports generated for manual review.

---

## Phase 10: Thread Pool + Parallel Dispatch

**Goal:** Route independent net groups in parallel.

**New files:**

| File | Lines (est.) | Purpose |
|------|-------------|---------|
| `src/router/thread_pool.zig` | ~200 | Work-stealing thread pool |
| `src/router/parallel_router.zig` | ~300 | Net dependency graph + parallel dispatch |

**Strategy:** See `GUIDE_03_THREADING_MODEL.md` for full design.

**Modified files:**

| File | Change |
|------|--------|
| `src/router/analog_db.zig` | Add per-thread arena support |
| `src/router/spatial_grid.zig` | Add thread-safe query (read-only during routing) |

**Exit criteria:** Speedup >= 3x on 8-core machine with 50+ net groups. Zero data races (detect via `std.Thread.Futex` or TSAN).

---

## Phase 11: Integration + Signoff

**Goal:** Wire everything together, run end-to-end on test circuits.

**Modified files:**

| File | Change |
|------|--------|
| `src/router/detailed.zig` | Add analog routing path before digital routing |
| `src/router/lib.zig` | Export `AnalogRouter` as primary API |

**Test circuits:**
1. Simple differential pair (2 nets, 4 pins)
2. Current mirror with matched devices (4 nets, 8 pins)
3. Bandgap reference with Kelvin connections
4. 8-bit DAC with capacitor array
5. Full mixed-signal block (analog core + digital periphery)

**Exit criteria:** Zero DRC violations. LVS clean. PEX matching within tolerance. All test circuits pass.

---

## File Map Summary

### New Files (12)

| File | Phase | Lines (est.) |
|------|-------|-------------|
| `src/router/analog_types.zig` | 1 | 200 |
| `src/router/analog_db.zig` | 1 | 400 |
| `src/router/spatial_grid.zig` | 2 | 500 |
| `src/router/analog_groups.zig` | 3 | 350 |
| `src/router/matched_router.zig` | 4 | 600 |
| `src/router/symmetric_steiner.zig` | 4 | 300 |
| `src/router/shield_router.zig` | 5 | 300 |
| `src/router/guard_ring.zig` | 6 | 400 |
| `src/router/thermal.zig` | 7 | 300 |
| `src/router/lde.zig` | 8 | 250 |
| `src/router/pex_feedback.zig` | 9 | 300 |
| `src/router/parallel_router.zig` | 10 | 300 |
| `src/router/analog_tests.zig` | 1-11 | 2000 |

**Total new: ~6,200 lines** (excluding tests: ~4,200)

### Modified Files (7)

| File | Phases |
|------|--------|
| `src/core/types.zig` | 1 |
| `src/router/lib.zig` | 1, 11 |
| `src/router/inline_drc.zig` | 2 |
| `src/router/astar.zig` | 4 |
| `src/router/steiner.zig` | 4 |
| `src/router/detailed.zig` | 11 |
| `src/characterize/pex.zig` | 9 |

---

## Dependency Graph

```
types.zig ─────────────────────────────────────────────────────────────┐
    │                                                                  │
    ▼                                                                  │
analog_types.zig ──┬──────────────────────────────────────────────┐    │
    │              │                                              │    │
    ▼              ▼                                              │    │
analog_db.zig   spatial_grid.zig                                  │    │
    │              │                                              │    │
    ├──────────────┤                                              │    │
    │              │                                              │    │
    ▼              ▼                                              │    │
analog_groups.zig                                                 │    │
    │                                                             │    │
    ├───────────┬───────────┬──────────┬──────────┐               │    │
    ▼           ▼           ▼          ▼          ▼               │    │
matched_     shield_     guard_     thermal.   lde.zig           │    │
router.zig   router.zig  ring.zig   zig                          │    │
    │           │           │          │          │               │    │
    ├───────────┴───────────┴──────────┴──────────┘               │    │
    ▼                                                             │    │
pex_feedback.zig ◄──── characterize/pex.zig                       │    │
    │                                                             │    │
    ▼                                                             │    │
parallel_router.zig                                               │    │
    │                                                             │    │
    ▼                                                             │    │
lib.zig ◄─── detailed.zig                                        │    │
```

---

## Build Integration

```zig
// build.zig — add to existing module list
const analog_mod = b.addModule("analog_router", .{
    .root_source_file = b.path("src/router/analog_db.zig"),
    .imports = &.{
        .{ .name = "types", .module = types_mod },
        .{ .name = "pdk", .module = pdk_mod },
    },
});

// Test target
const analog_tests = b.addTest(.{
    .root_source_file = b.path("src/router/analog_tests.zig"),
    .optimize = optimize,
});
```

---

## Risk Register

| Risk | Impact | Mitigation |
|------|--------|------------|
| PEX feedback loop doesn't converge | Can't guarantee matching | Cap iterations at 5, report best-effort |
| Thread contention on spatial grid | No speedup | Read-only grid during routing; rebuild between phases |
| Guard ring DRC interactions | False violations | Stitch-in strategy; post-route DRC verification |
| Thermal map accuracy | Bad routing decisions | User-supplied hotspots as primary; diffusion model as fallback |
| Memory pressure from SoA tables | OOM on large designs | Arena allocation with pre-computed capacity; comptime `@sizeOf` budgets |
| Zig 0.15.1 breaking changes | Won't compile | Pin to 0.15.1; use `nix develop --command` for all builds |
