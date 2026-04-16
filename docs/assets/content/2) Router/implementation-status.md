# Router Implementation Status

> Last audited: 2026-04-15
> Scope: all `.zig` files under `src/router/`, `src/lib.zig`, and phase/spec documents
> Purpose: exact inventory for developers deciding what to implement next

---

## 1. Summary Status Table

| Subsystem | File | Status | Notes |
|---|---|---|---|
| A* Search Engine | `src/router/astar.zig` | **COMPLETE** | 6-neighbor expansion, inline DRC hook, full tests |
| Maze / Channel Router | `src/router/maze.zig` | **COMPLETE** | M1 trunk + M2 vertical drop, LVS-safe pitch |
| Detailed Grid Router | `src/router/detailed.zig` | **PARTIAL** | Core routing done; analog integration path missing |
| Analog Types | `src/router/analog_types.zig` | **COMPLETE** | Type definitions only; no routing logic |
| Analog Group DB | `src/router/analog_groups.zig` | **COMPLETE** | SoA DB, dependency graph, priority sort |
| Analog Segment DB | `src/router/analog_db.zig` | **COMPLETE** | SoA CRUD, `toRouteArrays()`, `removeGroup()` |
| Analog Router (orchestrator) | `src/router/analog_router.zig` | **PARTIAL** | Main flow runs; `PexFeedback` stub empty; hardcoded PDK init |
| Matched Router | `src/router/matched_router.zig` | **PARTIAL** | Core route+balance done; thermal cost not wired |
| Guard Ring Inserter | `src/router/guard_ring.zig` | **COMPLETE** | Contact pitch, DRC registration, die-edge clipping |
| Shield Router | `src/router/shield_router.zig` | **COMPLETE** | Grounded/driven guard wires, via drops, DRC register |
| Symmetric Steiner | `src/router/symmetric_steiner.zig` | **COMPLETE** | Mirror axis from centroid, single-tree fallback |
| Parallel Router | `src/router/parallel_router.zig` | **PARTIAL** | Wavefront dispatch done; sequential stub empty; rip-up fakes |
| Thread Pool | `src/router/thread_pool.zig` | **PARTIAL** | Pool infra done; `WorkItem.execute()` emits zero-geometry |
| LDE Constraints | `src/router/lde.zig` | **DISCONNECTED** | Implemented; never imported by any routing file |
| PEX Feedback Loop | `src/router/pex_feedback.zig` | **COMPLETE** | `runPexFeedbackLoop()` exists with 5-iter repair; wiring missing |
| Spatial Grid (DRC) | `src/router/spatial_grid.zig` | **DISCONNECTED** | Structure implemented; DRC pipeline still uses O(n) scan |
| Thermal Map | `src/router/thermal.zig` | **DISCONNECTED** | `ThermalMap` implemented; cost never queried in matched_router |
| Analog Test Suite | `src/router/analog_tests.zig` | **PARTIAL** | Uses `PexGroupIdx` (undefined symbol); tests would fail to compile |
| Public API (`lib.zig`) | `src/lib.zig` | **INCOMPLETE** | Exports maze/detailed/drc/steiner/lp_sizing; analog subsystem absent |

---

## 2. Per-Subsystem Breakdown

### 2.1 `astar.zig` — A* Search Engine

**Implemented:**
- `AStarRouter.findPath()` with priority queue, 6-neighbor expansion (±preferred, ±cross, ±via)
- Inline DRC filter hook called during node expansion
- Full test coverage

**Nothing missing.** Baseline routing engine is production-ready.

---

### 2.2 `maze.zig` — Channel Router

**Implemented:**
- `routeAll()`: assigns per-net horizontal M1 trunks outside device pin clearance zone
- `routeNet()`: M1 stub + direct M2 vertical drop + M1 landing pad
- LVS-safe pitch formula (m1w + 2×snap + m1s)
- Trunk-bump loop: avoids landing trunk on foreign-net pin y-positions

**Nothing missing.** Used as baseline / fallback.

---

### 2.3 `detailed.zig` — Grid-Based Detailed Router

**Implemented:**
- `routeAll()`, `routeNet()`, `commitPath()`, `emitSegment()`
- `emitLShapeGridAware()` for L-shaped grid-aligned routes
- `ripUpNet()`, `ripUpAndReroute()` for congestion repair
- `astar_ok` / `astar_fail` counters

**Stubbed / Missing:**
- No `analog_router: ?*AnalogRouter` field — PHASE11_SPEC.md requires `DetailedRouter` to call `AnalogRouter.routeAll()` before digital routing
- No call path: `if (self.analog_router) |ar| try ar.routeAll(...)` never exists
- `emitLShape` / `emitLShapeM2` are internal helpers; no analog-aware path selection

---

### 2.4 `analog_router.zig` — Analog Orchestrator

**Implemented:**
- `routeAllGroups()`: calls `routeMatchedGroups()`, `routeShieldedGroups()`, `insertGuardRings()`
- `routeMatchedGroups()`, `routeShieldedGroups()`, `insertGuardRings()` delegate to subsystems
- `AnalogRouteDB` output assembly

**Stubbed / Missing:**
- `PexFeedback = struct {}` — the `PexFeedback` type in this file is an empty stub; `pex_feedback.zig` has the real implementation but is not imported
- `AnalogRouter.init()` calls `PdkConfig.loadDefault(.sky130)` hardcoded instead of using the `pdk` parameter passed to `routeAllGroups()`
- PEX feedback step commented out: `// 4. PEX feedback disabled — handled externally` — no external caller exists

---

### 2.5 `matched_router.zig` — Wire-Length / Via Matching

**Implemented:**
- `routeGroup()`: symmetric Steiner decomposition + A* per net
- `balanceWireLengths()`, `balanceViaCounts()`, `sameLayerEnforcement()`
- `emitToSegmentDB()`: SoA export

**Stubbed / Missing:**
- `thermal_map: ?*const thermal.ThermalMap` field stored but never queried
- A* expansion cost function does not call `self.thermal_map.?.query(x, y)` — thermal-aware detour routing not active
- No test covers thermal-influenced path choice

---

### 2.6 `parallel_router.zig` — Wavefront Parallel Router

**Implemented:**
- `GroupDependencyGraph.build()`, `colorGroups()` (graph coloring for conflict-free wavefronts)
- `routeAllGroups()`: wavefront dispatch with color-based parallel batches

**Stubbed / Missing:**
- `routeGroupsSequential()` body is entirely empty:
  ```zig
  _ = net_id; _ = allocator; _ = pex_cfg;
  ```
  No routing logic — returns without doing anything
- `ripUpAndRerouteConflicts()` emits fake offset segments (`x1 += 0.01 * conflict_id`) instead of calling the A* rerouter

---

### 2.7 `thread_pool.zig` — Thread Pool

**Implemented:**
- `ThreadPool.submitAndWait()`, `ThreadLocalState`, `detectSegmentConflicts()`, `mergeThreadLocalSegments()`
- `executeWithRouter()` method: calls real `MatchedRouter.routeGroup()`

**Stubbed / Missing:**
- `WorkItem.execute()` emits zero-geometry segments for all nets:
  ```zig
  // placeholder: emit zero-segment for this net
  try db.append(.{ .x1 = 0, .y1 = 0, .x2 = 0, .y2 = 0, ... });
  ```
- `executeWithRouter()` exists but is **never called** from `execute()` — the real routing path is dead code
- Thread pool submits `execute()`, not `executeWithRouter()`, so all parallel routing produces zero-length geometry

---

### 2.8 `lde.zig` — Layout Dependent Effects

**Implemented:**
- `LDEConstraintDB`: `addConstraint()`, `findByDevice()`, `generateKeepouts()`, `generateWPEKeepouts()`
- `computeLDECost()`, `computeLDECostScaled()` — cost values ready for A* integration

**Disconnected — never imported:**
- Zero import statements reference `lde.zig` anywhere in the codebase
- No call site in `astar.zig`, `detailed.zig`, or `matched_router.zig`
- SA/SB/SC_target constraints from IMPL_PLAN.md are computed but never applied

---

### 2.9 `pex_feedback.zig` — PEX Feedback Loop

**Implemented:**
- `extractNet()`: filters RouteArrays by net, calls `pex_mod.extractFromRoutes()`
- `computeMatchReport()`: R/C/length/via/coupling ratios with pass/fail and `FailureReason`
- `repairWidths()`, `repairLength()`, `repairVias()`, `repairCoupling()`
- `repairFromPexReport()`: dispatches repair based on `FailureReason`
- `runPexFeedbackLoop()`: full 5-iteration loop (extract → report → repair → repeat)
- `selectRepairAction()`: priority-ranked action selector
- `MatchReportDB`: SoA storage for per-group reports

**Disconnected:**
- `analog_router.zig` has `PexFeedback = struct {}` — an empty stub that shadows the real implementation
- `analog_router.zig` does not `@import("pex_feedback.zig")`
- `runPexFeedbackLoop()` is never called from any routing orchestrator

---

### 2.10 `spatial_grid.zig` — Spatial DRC Accelerator

**Implemented:**
- Uniform 2D grid structure, `init()`, `deinit()`, cell lookup by coordinate
- `insertSegment()`, `queryNear()` for O(1) spatial lookup

**Disconnected:**
- `InlineDrcChecker.checkSpacing()` in `astar.zig` still uses O(n) linear scan over all route segments
- `SpatialGrid` is never instantiated as the DRC backing store
- PHASE1_SPEC.md specifies `SpatialDrcChecker` as the replacement but it is not wired

---

### 2.11 `thermal.zig` — Thermal Map

**Implemented:**
- `ThermalMap.init()`, `deinit()`, `addHotspot()` (Gaussian spreading), `query(x, y)` → temperature

**Disconnected:**
- `matched_router.zig` stores `thermal_map: ?*const ThermalMap` but the field is never read during A* cost computation
- No routing decision is influenced by thermal data

---

### 2.12 `analog_tests.zig` — Analog Test Suite

**Partial / Broken:**
- Tests reference `PexGroupIdx` (undefined — should be `AnalogGroupIdx` from `core_types`)
- Line 26: `const idx = PexGroupIdx.fromInt(42)` — `PexGroupIdx` not imported, not defined
- Lines 51–53, 85: same undefined symbol repeated
- Tests for `Rect`, `AnalogSegmentDB`, `SpatialGrid`, `SymmetricSteiner` are structurally correct

---

### 2.13 `src/lib.zig` — Public API Surface

**Current exports:** `maze`, `detailed`, `drc`, `steiner`, `lp_sizing`

**Missing per PHASE11_SPEC.md:**
- `AnalogRouter` (from `analog_router.zig`)
- `MatchReportDB` (from `pex_feedback.zig`)
- `ThreadPool` (from `thread_pool.zig`)
- `PexFeedbackLoop` / `runPexFeedbackLoop` (from `pex_feedback.zig`)
- `LDEConstraintDB` (from `lde.zig`)
- `ThermalMap` (from `thermal.zig`)

---

## 3. TODO Inventory

| File | Location | Verbatim Comment / Issue | What to Do |
|---|---|---|---|
| `analog_router.zig` | `PexFeedback = struct {}` | Empty stub struct | Replace with `@import("pex_feedback.zig")` and wire `runPexFeedbackLoop()` |
| `analog_router.zig` | `routeAllGroups()` step 4 | `// 4. PEX feedback disabled — handled externally` | Call `pex_feedback.runPexFeedbackLoop()` per matched group here |
| `analog_router.zig` | `AnalogRouter.init()` | `PdkConfig.loadDefault(.sky130)` hardcoded | Accept `pdk: *const PdkConfig` parameter and pass through |
| `matched_router.zig` | A* cost function | `thermal_map` field stored, never read | Add `if (self.thermal_map) |tm| cost += tm.query(x, y) * THERMAL_WEIGHT` in expansion |
| `parallel_router.zig` | `routeGroupsSequential()` | `_ = net_id; _ = allocator; _ = pex_cfg;` — empty body | Implement: iterate nets, call `MatchedRouter.routeGroup()` per net |
| `parallel_router.zig` | `ripUpAndRerouteConflicts()` | Emits `x1 += 0.01 * conflict_id` fake segments | Call `DetailedRouter.ripUpAndReroute()` on conflicting nets |
| `thread_pool.zig` | `WorkItem.execute()` | `// placeholder: emit zero-segment for this net` | Call `self.executeWithRouter()` instead of emitting zero-geometry |
| `lde.zig` | Entire file | Never imported | Import in `astar.zig`; pass `LDEConstraintDB` to `findPath()`; add LDE cost term |
| `spatial_grid.zig` | `InlineDrcChecker` | O(n) scan still used | Replace linear scan with `SpatialGrid.queryNear()` in `checkSpacing()` |
| `thermal.zig` | `ThermalMap.query()` | Implemented but unreachable | Wire into `matched_router.zig` A* cost; expose via `lib.zig` |
| `analog_tests.zig` | Lines 26, 51, 52, 85 | `PexGroupIdx` — undefined symbol | Replace with `AnalogGroupIdx` (imported from `core_types`) |
| `detailed.zig` | `DetailedRouter` struct | No `analog_router` field | Add `analog_router: ?*AnalogRouter`; call before digital routing per PHASE11_SPEC |
| `src/lib.zig` | Module exports | Missing analog subsystem | Export `AnalogRouter`, `MatchReportDB`, `ThreadPool`, `runPexFeedbackLoop`, `LDEConstraintDB`, `ThermalMap` |

---

## 4. Disconnected Subsystems

### `lde.zig`
- **What it does:** Computes SA/SB/SC keepout regions and WPE cost values per device. `computeLDECost()` returns a scalar suitable for A* cost augmentation.
- **Where it should be called:** `astar.zig` node expansion — add LDE cost to `g_score` when the candidate cell overlaps a keepout region.
- **What is missing:** `@import("lde.zig")` in `astar.zig` or `detailed.zig`; pass `lde_db: ?*const LDEConstraintDB` through `findPath()` signature; call `lde_db.computeLDECostScaled(x, y, layer)` during expansion.

### `thermal.zig` (cost path)
- **What it does:** `ThermalMap.query(x, y)` returns temperature at a grid point based on Gaussian hotspot model.
- **Where it should be called:** `matched_router.zig` inside the A* cost function during `routeGroup()` expansion.
- **What is missing:** Read `self.thermal_map.?.query(node.x, node.y)` and add `THERMAL_WEIGHT * temp` to the A* edge cost.

### `pex_feedback.zig` (loop entry)
- **What it does:** `runPexFeedbackLoop()` iterates extract → report → repair up to 5 times for a 2-net matched group.
- **Where it should be called:** `analog_router.zig` `routeAllGroups()` step 4 — after matched groups are routed, before exporting to `AnalogRouteDB`.
- **What is missing:** `@import("pex_feedback.zig")` in `analog_router.zig`; remove `PexFeedback = struct {}`; call `pex_feedback.runPexFeedbackLoop()` per group with the group's two net indices, tolerance from group spec, and `pex_cfg`.

### `spatial_grid.zig` (DRC acceleration)
- **What it does:** O(1) spatial cell lookup; `queryNear()` returns candidate segments within a bounding box.
- **Where it should be called:** `InlineDrcChecker.checkSpacing()` in `astar.zig` as replacement for O(n) linear scan.
- **What is missing:** Pass `SpatialGrid` pointer into `AStarRouter` init or `findPath()`; call `grid.queryNear(bbox)` instead of iterating all segments; update segment insertion to also call `grid.insertSegment()`.

---

## 5. Phase Completion Status

| Phase | Description | Status | Blocking Issues |
|---|---|---|---|
| Phase 1 | ID types, SpatialGrid, AnalogSegmentDB | **COMPLETE** (data structures) | `analog_tests.zig` has `PexGroupIdx` compile error |
| Phase 2 | AnalogGroupDB, dependency graph, priority sort | **COMPLETE** | None |
| Phase 3 | SymmetricSteiner — axis detection, tree mirroring | **COMPLETE** | None |
| Phase 4 | MatchedRouter — wire-length + via balancing | **PARTIAL** | Thermal cost not wired |
| Phase 5 | GuardRingInserter — contact pitch, die-edge clip | **COMPLETE** | None |
| Phase 6 | ShieldRouter — guard wires, via drops | **COMPLETE** | None |
| Phase 7 | ThermalMap — Gaussian model, `query()` | **COMPLETE** (isolated) | Not connected to Phase 4 cost |
| Phase 8 | LDE constraints — SA/SB/SC keepouts, WPE cost | **COMPLETE** (isolated) | Never imported; no call site |
| Phase 9 | PEX feedback loop — extract → report → repair | **COMPLETE** (isolated) | Not called from analog_router.zig |
| Phase 10 | ParallelRouter — graph coloring, wavefront dispatch | **PARTIAL** | `routeGroupsSequential()` empty; rip-up fakes geometry |
| Phase 11 | Integration — lib.zig exports, DetailedRouter wiring | **NOT STARTED** | No analog_router field in detailed.zig; lib.zig exports missing |

---

## 6. Critical Gaps

These gaps block production use of the analog router:

**GAP-1: Thread pool routes nothing (P0)**
`WorkItem.execute()` in `thread_pool.zig` emits zero-length placeholder segments. `executeWithRouter()` has the real implementation but is never called. All parallel routing silently produces empty geometry.

**GAP-2: PEX feedback loop unreachable (P0)**
`pex_feedback.runPexFeedbackLoop()` is fully implemented but never called. `analog_router.zig` has an empty `PexFeedback = struct {}` stub. Matched-group routing exits without any parasitic verification or repair.

**GAP-3: Analog subsystem not integrated into DetailedRouter (P0)**
`detailed.zig` has no `analog_router` field. PHASE11_SPEC.md requires `DetailedRouter` to call `AnalogRouter.routeAll()` before digital routing. Currently the two routers cannot interoperate.

**GAP-4: `routeGroupsSequential()` is empty (P1)**
`parallel_router.zig` sequential fallback does nothing. Any single-threaded analog routing invocation produces no output.

**GAP-5: LDE constraints never applied (P1)**
`lde.zig` computes keepout costs but is never imported. SA/SB spacing violations from layout-dependent effects are not enforced during routing.

**GAP-6: Thermal detour routing inactive (P1)**
`matched_router.zig` stores a `ThermalMap` pointer but never reads it. Isotherm-aware routing produces the same paths as thermal-blind routing.

**GAP-7: `analog_tests.zig` fails to compile (P1)**
`PexGroupIdx` is referenced but undefined. The analog test suite cannot build until this is corrected to `AnalogGroupIdx`.

**GAP-8: SpatialGrid DRC not wired (P2)**
`InlineDrcChecker` still runs O(n) linear scan. `SpatialGrid` exists but is not used as the DRC backing store. Performance degrades quadratically with segment count.

**GAP-9: `analog_router.zig` hardcodes PDK (P2)**
`PdkConfig.loadDefault(.sky130)` in `AnalogRouter.init()` ignores any PDK passed by the caller. Non-SKY130 targets silently use wrong design rules.

**GAP-10: `lib.zig` missing analog exports (P2)**
Six public types specified by PHASE11_SPEC.md are absent from `src/lib.zig`. Downstream callers cannot access `AnalogRouter`, `MatchReportDB`, `ThreadPool`, `runPexFeedbackLoop`, `LDEConstraintDB`, or `ThermalMap`.

---

## 7. Pipeline Diagram

```svg
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1000 700" width="1000" height="700" style="background:#060C18;font-family:Inter,sans-serif;">

  <!-- Title -->
  <text x="500" y="36" text-anchor="middle" fill="#B8D0E8" font-size="15" font-weight="600">Spout Analog Router Pipeline — Implementation Status</text>

  <!-- Legend -->
  <rect x="20" y="55" width="14" height="14" rx="3" fill="#43A047"/>
  <text x="40" y="66" fill="#B8D0E8" font-size="11">Complete</text>
  <rect x="110" y="55" width="14" height="14" rx="3" fill="#FB8C00"/>
  <text x="130" y="66" fill="#B8D0E8" font-size="11">Partial</text>
  <rect x="195" y="55" width="14" height="14" rx="3" fill="#EF5350"/>
  <text x="215" y="66" fill="#B8D0E8" font-size="11">Stub / Empty</text>
  <rect x="315" y="55" width="14" height="14" rx="3" fill="#3E5E80"/>
  <text x="335" y="66" fill="#B8D0E8" font-size="11">Disconnected</text>

  <!-- Row 1: Input layer -->
  <!-- NetArrays/DeviceArrays/PinEdgeArrays (input) -->
  <rect x="20" y="100" width="150" height="46" rx="6" fill="#1A2840" stroke="#3E5E80" stroke-width="1.5"/>
  <text x="95" y="120" text-anchor="middle" fill="#B8D0E8" font-size="11" font-weight="600">NetArrays</text>
  <text x="95" y="136" text-anchor="middle" fill="#7A9CC0" font-size="10">DeviceArrays · PinEdgeArrays</text>

  <!-- PdkConfig (input) -->
  <rect x="195" y="100" width="130" height="46" rx="6" fill="#1A2840" stroke="#3E5E80" stroke-width="1.5"/>
  <text x="260" y="120" text-anchor="middle" fill="#B8D0E8" font-size="11" font-weight="600">PdkConfig</text>
  <text x="260" y="136" text-anchor="middle" fill="#EF5350" font-size="10">hardcoded in analog_router</text>

  <!-- AnalogGroupDB (input) -->
  <rect x="350" y="100" width="140" height="46" rx="6" fill="#1A2840" stroke="#43A047" stroke-width="1.5"/>
  <text x="420" y="120" text-anchor="middle" fill="#B8D0E8" font-size="11" font-weight="600">AnalogGroupDB</text>
  <text x="420" y="136" text-anchor="middle" fill="#43A047" font-size="10">analog_groups.zig ✓</text>

  <!-- LDEConstraintDB (disconnected input) -->
  <rect x="515" y="100" width="150" height="46" rx="6" fill="#1A2840" stroke="#3E5E80" stroke-width="1.5"/>
  <text x="590" y="120" text-anchor="middle" fill="#B8D0E8" font-size="11" font-weight="600">LDEConstraintDB</text>
  <text x="590" y="136" text-anchor="middle" fill="#3E5E80" font-size="10">lde.zig — never imported</text>

  <!-- ThermalMap (disconnected input) -->
  <rect x="690" y="100" width="150" height="46" rx="6" fill="#1A2840" stroke="#3E5E80" stroke-width="1.5"/>
  <text x="765" y="120" text-anchor="middle" fill="#B8D0E8" font-size="11" font-weight="600">ThermalMap</text>
  <text x="765" y="136" text-anchor="middle" fill="#3E5E80" font-size="10">thermal.zig — cost unwired</text>

  <!-- Row 2: AnalogRouter orchestrator -->
  <!-- Arrow down from inputs to AnalogRouter -->
  <line x1="420" y1="146" x2="420" y2="195" stroke="#3E5E80" stroke-width="1.5" marker-end="url(#arr)"/>

  <rect x="250" y="195" width="340" height="50" rx="7" fill="#1C3050" stroke="#FB8C00" stroke-width="2"/>
  <text x="420" y="218" text-anchor="middle" fill="#B8D0E8" font-size="12" font-weight="700">AnalogRouter</text>
  <text x="420" y="235" text-anchor="middle" fill="#FB8C00" font-size="10">analog_router.zig — PEX stub empty · PDK hardcoded</text>

  <!-- Row 3: Three parallel subsystems -->
  <!-- Arrow to MatchedRouter -->
  <line x1="310" y1="245" x2="180" y2="300" stroke="#3E5E80" stroke-width="1.5" marker-end="url(#arr)"/>
  <!-- Arrow to ShieldRouter -->
  <line x1="420" y1="245" x2="490" y2="300" stroke="#3E5E80" stroke-width="1.5" marker-end="url(#arr)"/>
  <!-- Arrow to GuardRing -->
  <line x1="530" y1="245" x2="760" y2="300" stroke="#3E5E80" stroke-width="1.5" marker-end="url(#arr)"/>

  <!-- MatchedRouter -->
  <rect x="60" y="300" width="240" height="50" rx="7" fill="#1C3050" stroke="#FB8C00" stroke-width="2"/>
  <text x="180" y="323" text-anchor="middle" fill="#B8D0E8" font-size="12" font-weight="700">MatchedRouter</text>
  <text x="180" y="339" text-anchor="middle" fill="#FB8C00" font-size="10">matched_router.zig — thermal cost unwired</text>

  <!-- ShieldRouter -->
  <rect x="355" y="300" width="200" height="50" rx="7" fill="#1C3050" stroke="#43A047" stroke-width="2"/>
  <text x="455" y="323" text-anchor="middle" fill="#B8D0E8" font-size="12" font-weight="700">ShieldRouter</text>
  <text x="455" y="339" text-anchor="middle" fill="#43A047" font-size="10">shield_router.zig ✓</text>

  <!-- GuardRingInserter -->
  <rect x="620" y="300" width="200" height="50" rx="7" fill="#1C3050" stroke="#43A047" stroke-width="2"/>
  <text x="720" y="323" text-anchor="middle" fill="#B8D0E8" font-size="12" font-weight="700">GuardRingInserter</text>
  <text x="720" y="339" text-anchor="middle" fill="#43A047" font-size="10">guard_ring.zig ✓</text>

  <!-- Row 4: A* + Steiner under MatchedRouter -->
  <line x1="140" y1="350" x2="120" y2="395" stroke="#3E5E80" stroke-width="1.5" marker-end="url(#arr)"/>
  <line x1="220" y1="350" x2="240" y2="395" stroke="#3E5E80" stroke-width="1.5" marker-end="url(#arr)"/>

  <!-- AStarRouter -->
  <rect x="30" y="395" width="170" height="46" rx="6" fill="#1C3050" stroke="#43A047" stroke-width="2"/>
  <text x="115" y="416" text-anchor="middle" fill="#B8D0E8" font-size="11" font-weight="600">AStarRouter</text>
  <text x="115" y="431" text-anchor="middle" fill="#43A047" font-size="10">astar.zig ✓</text>

  <!-- SymmetricSteiner -->
  <rect x="215" y="395" width="170" height="46" rx="6" fill="#1C3050" stroke="#43A047" stroke-width="2"/>
  <text x="300" y="416" text-anchor="middle" fill="#B8D0E8" font-size="11" font-weight="600">SymmetricSteiner</text>
  <text x="300" y="431" text-anchor="middle" fill="#43A047" font-size="10">symmetric_steiner.zig ✓</text>

  <!-- Row 4: PEX Feedback (right side) -->
  <line x1="420" y1="245" x2="680" y2="395" stroke="#EF5350" stroke-width="1.5" stroke-dasharray="6,3" marker-end="url(#arrd)"/>

  <!-- PEX Feedback -->
  <rect x="570" y="395" width="200" height="46" rx="6" fill="#1C3050" stroke="#EF5350" stroke-width="2"/>
  <text x="670" y="416" text-anchor="middle" fill="#B8D0E8" font-size="11" font-weight="600">PEX Feedback Loop</text>
  <text x="670" y="431" text-anchor="middle" fill="#EF5350" font-size="10">pex_feedback.zig — never called</text>

  <!-- Row 5: ParallelRouter + ThreadPool -->
  <!-- Arrows down from MatchedRouter -->
  <line x1="180" y1="350" x2="180" y2="460" stroke="#3E5E80" stroke-width="1.5" stroke-dasharray="4,3"/>
  <line x1="180" y1="460" x2="225" y2="475" stroke="#3E5E80" stroke-width="1.5" marker-end="url(#arr)"/>
  <line x1="180" y1="460" x2="445" y2="475" stroke="#3E5E80" stroke-width="1.5" marker-end="url(#arr)"/>

  <!-- ParallelRouter -->
  <rect x="80" y="475" width="240" height="50" rx="7" fill="#1C3050" stroke="#FB8C00" stroke-width="2"/>
  <text x="200" y="498" text-anchor="middle" fill="#B8D0E8" font-size="12" font-weight="700">ParallelRouter</text>
  <text x="200" y="514" text-anchor="middle" fill="#EF5350" font-size="10">sequential stub empty · rip-up fakes geometry</text>

  <!-- ThreadPool -->
  <rect x="355" y="475" width="200" height="50" rx="7" fill="#1C3050" stroke="#EF5350" stroke-width="2"/>
  <text x="455" y="498" text-anchor="middle" fill="#B8D0E8" font-size="12" font-weight="700">ThreadPool</text>
  <text x="455" y="514" text-anchor="middle" fill="#EF5350" font-size="10">execute() emits zero-geometry</text>

  <!-- Row 6: Output -->
  <!-- Arrows to output -->
  <line x1="200" y1="525" x2="380" y2="580" stroke="#3E5E80" stroke-width="1.5" marker-end="url(#arr)"/>
  <line x1="455" y1="525" x2="430" y2="580" stroke="#3E5E80" stroke-width="1.5" marker-end="url(#arr)"/>
  <line x1="455" y1="350" x2="455" y2="600" stroke="#43A047" stroke-width="1" stroke-dasharray="3,4"/>

  <!-- RouteArrays / AnalogRouteDB output -->
  <rect x="280" y="580" width="280" height="46" rx="7" fill="#1A2840" stroke="#43A047" stroke-width="2"/>
  <text x="420" y="602" text-anchor="middle" fill="#B8D0E8" font-size="12" font-weight="700">RouteArrays / AnalogRouteDB</text>
  <text x="420" y="618" text-anchor="middle" fill="#43A047" font-size="10">analog_db.zig · toRouteArrays() ✓</text>

  <!-- lib.zig missing exports note -->
  <rect x="620" y="575" width="360" height="50" rx="6" fill="#1A1A2A" stroke="#EF5350" stroke-width="1.5" stroke-dasharray="6,3"/>
  <text x="800" y="596" text-anchor="middle" fill="#EF5350" font-size="10" font-weight="600">src/lib.zig — analog subsystem NOT exported</text>
  <text x="800" y="612" text-anchor="middle" fill="#7A9CC0" font-size="10">AnalogRouter · MatchReportDB · ThreadPool</text>
  <text x="800" y="627" text-anchor="middle" fill="#7A9CC0" font-size="10">runPexFeedbackLoop · LDEConstraintDB · ThermalMap</text>

  <!-- SpatialGrid disconnected note -->
  <rect x="620" y="460" width="200" height="46" rx="6" fill="#1A2840" stroke="#3E5E80" stroke-width="1.5" stroke-dasharray="4,3"/>
  <text x="720" y="481" text-anchor="middle" fill="#B8D0E8" font-size="11" font-weight="600">SpatialGrid (DRC)</text>
  <text x="720" y="496" text-anchor="middle" fill="#3E5E80" font-size="10">spatial_grid.zig — O(n) scan still used</text>

  <!-- Arrowhead markers -->
  <defs>
    <marker id="arr" markerWidth="8" markerHeight="8" refX="6" refY="3" orient="auto">
      <path d="M0,0 L0,6 L8,3 z" fill="#3E5E80"/>
    </marker>
    <marker id="arrd" markerWidth="8" markerHeight="8" refX="6" refY="3" orient="auto">
      <path d="M0,0 L0,6 L8,3 z" fill="#EF5350"/>
    </marker>
  </defs>
</svg>
```

---

*Generated from source audit of 18 `.zig` files and 5 spec/plan documents. No assumptions made — all status reflects actual code, not spec intent.*
