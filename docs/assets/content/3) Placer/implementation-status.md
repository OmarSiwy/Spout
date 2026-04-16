# Placer Implementation Status

> Audit date: 2026-04-15. Based on full read of all placer/, constraint/, characterize/, liberty/ source files and lib.zig.

---

## Summary Table

| Subsystem | File | Status | Notes |
|---|---|---|---|
| Cost function — HPWL | `placer/cost.zig` | ✅ Implemented | Normalized by num_nets, power nets excluded |
| Cost function — Area | `placer/cost.zig` | ✅ Implemented | Bounding-box area of all device positions |
| Cost function — Symmetry (X-axis) | `placer/cost.zig` | ✅ Implemented | L1/L2 norm, `axis_x` field |
| Cost function — Symmetry (Y-axis) | `placer/cost.zig` | ✅ Implemented | `axis_y` field, `symmetry_y` constraint type |
| Cost function — Matching | `placer/cost.zig` | ✅ Implemented | Parabolic well at min-separation |
| Cost function — Proximity | `placer/cost.zig` | ✅ Implemented | Squared excess beyond threshold |
| Cost function — Isolation | `placer/cost.zig` | ✅ Implemented | Squared violation below threshold |
| Cost function — RUDY congestion | `placer/cost.zig` | ✅ Implemented | Overflow metric, incremental update |
| Cost function — Overlap | `placer/cost.zig` | ✅ Implemented | AABB overlap area for all pairs |
| Cost function — Thermal mismatch | `placer/cost.zig` | ✅ Implemented | Inverse-square heat model, piggybacks on matching |
| Cost function — Orientation mismatch | `placer/cost.zig` | ✅ Implemented | Binary penalty per `orientation_match` constraint |
| Cost function — LDE (SA/SB) | `placer/cost.zig` | ✅ Implemented | STI distance equalization for matched pairs |
| Cost function — Common-centroid | `placer/cost.zig` | ✅ Implemented | Group sidecar, squared centroid distance |
| Cost function — Parasitic balance | `placer/cost.zig` | ✅ Implemented | Manhattan routing-length imbalance |
| Cost function — Interdigitation | `placer/cost.zig` | ✅ Implemented | Centroid + adjacency violations + spacing variance |
| Cost function — Edge penalty | `placer/cost.zig` | ✅ Implemented | Exposed-edge asymmetry for matched pairs |
| Cost function — WPE mismatch | `placer/cost.zig` | ✅ Implemented | Well-edge distance imbalance |
| Guard ring validation | `placer/cost.zig` | ✅ Implemented | Post-SA check, `checkGuardRings` |
| Dummy device insertion | `placer/cost.zig` | ✅ Implemented | Post-SA `insertDummies`, `isEdgeExposed` |
| SA engine — translate move | `placer/sa.zig` | ✅ Implemented | Adaptive ρ(T), template bounds clamping |
| SA engine — swap / mirror_swap | `placer/sa.zig` | ✅ Implemented | X- and Y-axis mirror; symmetry-aware |
| SA engine — orientation flip | `placer/sa.zig` | ✅ Implemented | All 8 DEF orientations |
| SA engine — group translate | `placer/sa.zig` | ✅ Implemented | Shifts entire centroid group half |
| SA engine — macro_translate | `placer/sa.zig` | 🔌 Declared, unreachable in runOneMove | Only dispatched from `runSaHierarchical` internals |
| SA engine — macro_transform | `placer/sa.zig` | 🔌 Declared, unreachable in runOneMove | Same as above |
| SA schedule — κ·N two-level | `placer/sa.zig` | ✅ Implemented | Three-phase α, reheating |
| SA schedule — legacy flat loop | `placer/sa.zig` | ✅ Implemented | Backward-compat when `kappa == 0` |
| Hierarchical SA | `placer/sa.zig` | ✅ Implemented | Phase 1 (unit-cell) + Phase 2 (super-device) + Phase 1b |
| RUDY grid | `placer/rudy.zig` | ✅ Implemented | Incremental, tile-based, overflow metric |
| Constraint extraction — diff pair | `constraint/extract.zig` | ✅ Implemented | isSeedPair, load/cascode traversal |
| Constraint extraction — current mirror | `constraint/extract.zig` | ✅ Implemented | 1:1 and ratio variants |
| Constraint extraction — cascode | `constraint/extract.zig` | ✅ Implemented | proximity constraint emitted |
| Constraint extraction — passive pair | `constraint/extract.zig` | ✅ Implemented | R/C pair matching |
| Constraint extraction — ML augment | `constraint/extract.zig` | ✅ Implemented | `addConstraintsFromML` parses binary blob |
| Constraint types: symmetry / matching / proximity / isolation | `core/types.zig` | ✅ Implemented | Enum values 0–3 |
| Constraint types: symmetry_y / orientation_match / common_centroid / interdigitation | `core/types.zig` | ✅ Implemented | Enum values 4–7 |
| DeviceArrays — orientations | `core/device_arrays.zig` | ✅ Implemented | Flat parallel `[]Orientation`, zero-init `.N` |
| DeviceArrays — is_dummy | `core/device_arrays.zig` | ✅ Implemented | Flat `[]bool`, all false |
| DeviceArrays — embeddings / predicted_cap | `core/device_arrays.zig` | ✅ Implemented | Populated via `spout_set_device_embeddings` |
| Device dimension computation | `src/lib.zig` | ✅ Implemented | MOSFET, R, C, gate-cap with PDK geometry |
| Pin offset computation | `core/pin_edge_arrays.zig` | ✅ Implemented | Called from `spout_parse_netlist` |
| Gradient refinement | `src/lib.zig` | ❌ Stub | `spout_run_gradient_refinement` returns 0, placeholder comment |
| ML constraint write-back (`spout_set_constraints_from_ml`) | `src/lib.zig` | ❌ Stub | Comment: "not yet implemented" |
| Python `SaConfig` ABI struct | `python/config.py` | ❌ Mismatched | See critical issue below |
| Characterize subsystem | `characterize/*.zig` | 🔌 Implemented but NOT called from placer flow | DRC/LVS/PEX run post-GDSII via external tools |
| Liberty generation | `liberty/lib.zig` | ✅ Implemented | Timing, power, area, NLDM tables, multi-corner |
| Liberty — PDK corner auto-discovery | `liberty/TODO.md` | ❌ Not implemented | Static comptime data only |
| Liberty — ADC validation test | `liberty/TODO.md` | ❌ Not implemented | Specced but no code exists |
| Placer → Router handoff | `src/lib.zig` | ⚠️ Partial | Positions written but SA extended inputs not passed |
| Placer → Liberty timing awareness | (none) | ❌ Missing | Placer has no Liberty/timing data path |

---

## End-to-End Flow Trace

### Entry point: `layout.run_sa_placement(config_bytes)` in Python

**Step 1 — Python `run_pipeline()` in `python/main.py`**
- Calls `layout.parse_netlist(path)` → Zig `spout_parse_netlist`
- Calls `layout.extract_constraints()` → Zig `spout_extract_constraints`
- Calls `layout.run_sa_placement(config_bytes)` → Zig `spout_run_sa_placement`
- Calls `layout.run_routing()` → Zig `spout_run_routing`
- Calls `layout.export_gdsii_named(path, cell)` → Zig `spout_export_gdsii_named`
- **Chain is intact through all five stages.**

**Step 2 — `spout_parse_netlist` (lib.zig:342)**
- Parser → SoA device/net/pin arrays populated
- `computePinOffsets` called — pin spatial positions assigned
- `computeDeviceDimensions` called — physical bounding boxes computed
- `FlatAdjList.build` called — CSR net-to-pin adjacency built
- `detectMacros` called automatically
- **Returns 0 on success.**

**Step 3 — `spout_extract_constraints` (lib.zig:529)**
- Calls `constraint_extract.extractConstraints` — O(n²) pattern matching
- Emits `symmetry`, `matching`, `proximity` constraints
- Stores in `ctx.constraints`
- **axis field is NaN (axis unknown until placement) — this is correct, SA recalculates.**

**Step 4 — `spout_run_sa_placement` (lib.zig:705)**
- Deserializes `SaConfig` from raw bytes — **CRITICAL ISSUE:** Python `_SaConfigC` has 25 fields; Zig `SaConfig` has a different field layout with different names and different count. The `sizeof` check at line 714 will **silently use defaults** whenever sizes differ.
- Builds `PinInfo[]` with centre-offset-adjusted pin positions
- Builds `placer_adj` (NetAdjacency) from `FlatAdjList`
- Builds `placer_constraints[]` from `ctx.constraints` — **axis_y is always 0.0, param is always 0.0** (hardcoded at lib.zig:828–831)
- Calls `sa.runSa(...)` with `extended: .{}` — **all extended inputs (centroid_groups, heat_sources, interdigitation_groups, well_regions) are permanently empty slices**
- **Result object is ignored** (`_ = result;` at line 872) — dummy_count and guard_ring_results thrown away
- Shifts positions back from centres to origins
- **Chain does not break here, but the SA runs with zero extended inputs regardless of what constraints were extracted.**

**Step 5 — `spout_run_routing` (lib.zig:1046)**
- Calls `detailed.DetailedRouter.routeAll` — reads `ctx.devices.positions` (just updated by SA)
- Runs rip-up-and-reroute
- Stores routes in `ctx.routes`
- **The router reads the placer's output positions directly. This handoff works.**

**Step 6 — GDSII export, DRC, LVS, PEX**
- GDSII writer reads `ctx.devices.positions` and `ctx.routes`
- DRC/LVS/PEX: delegated entirely to KLayout and Magic external tools via Python `tools.py`
- **In-engine `characterize/` subsystem (drc.zig, lvs.zig, pex.zig) is never called from this flow.**

### Where the chain breaks

1. **Python ABI struct mismatch (critical):** `python/config.py:_SaConfigC` defines 25 fields (`wTiming`, `wEmbedSimilarity`, `adaptiveCooling`, `adaptiveWindow`, `reheatFraction`, `stallWindowsBeforeReheat`, `numStarts`, delay parameters) that **do not exist** in the Zig `SaConfig` extern struct. The `sizeof(_SaConfigC)` will not equal `@sizeOf(SaConfig)`, so `spout_run_sa_placement` always falls back to default weights. No Python-specified weights (w_symmetry, w_matching, etc.) ever reach the SA engine.

2. **Extended inputs never populated:** `spout_run_sa_placement` always calls `sa.runSa(..., .{})`. The centroid groups, heat sources, interdigitation groups, and well regions are never passed. The cost terms for common-centroid, thermal, interdigitation, and WPE are computed as 0.0 on every run because their input slices are empty.

3. **`axis_y` and `param` always zero in placer constraints:** When translating `ctx.constraints` to `placer_constraints` in lib.zig, `axis_y` and `param` are hardcoded to 0.0. Proximity/isolation `param` (distance threshold) and Y-axis symmetry `axis_y` are permanently zero.

4. **Gradient refinement is a stub:** `spout_run_gradient_refinement` returns 0 immediately. No gradient-based post-processing exists.

5. **`spout_set_constraints_from_ml` is a stub:** Returns 0 immediately with a placeholder comment.

---

## Per-File Breakdown

### `placer/cost.zig` (2281 lines)

**Implemented:**
- All 16 cost terms with full implementations
- `computeFull` — full evaluation of all 16 terms
- `computeDeltaCost` — incremental evaluation for SA moves
- `acceptDelta` — commits new sub-costs (17 scalar parameters — fragile, see below)
- `acceptTotal` — fast path (total only)
- `insertDummies` — post-SA dummy device insertion with edge detection
- `checkGuardRings` — post-SA guard ring validation
- `transformPinOffset` — 8 DEF orientation transforms
- `computeDeviceSaSb` — SA/SB approximation from neighboring geometry
- Inline module tests for most pure functions

**Structurally fragile:**
- `acceptDelta` takes 17 individual `f32` parameters. Adding a new cost term requires updating every call site in sa.zig (there are 4: translate, swap, orientation_flip, group_translate). The IMPL_PLAN.md suggests bundling into `DeltaResult` — not yet done.

**Dead code / never triggered at runtime:**
- All terms beyond HPWL/area/symmetry/matching/overlap are structurally implemented but never receive non-zero inputs from the main pipeline (extended inputs always `&.{}`).

**Stubbed:**
- `countExposedEdges` ignores `layout_width` and `layout_height` parameters: `_ = layout_width; _ = layout_height;` — boundary-exposure from array edges is not checked, only neighbor proximity.

### `placer/sa.zig` (2075 lines)

**Implemented:**
- `runSa` — full κ·N schedule with reheating, greedy initial placement, template bounds
- `runOneMove` — dispatches translate/swap/orientation_flip/group_translate
- `runTranslateMove` — adaptive ρ(T), template bounds rejection
- `runSwapMove` — plain swap + X/Y mirror swap for symmetry constraints
- `runOrientationFlipMove` — all 8 DEF orientations
- `runGroupTranslateMove` — group translate for centroid groups
- `runSaHierarchical` — phase 1 (unit-cell SA) + phase 2 (super-device SA) + phase 1b
- `buildDeviceNets` — device-to-net mapping for incremental RUDY
- `recomputeAllPinPositions` / `updatePinPositionsForDevice` — orientation-aware

**Declared but `unreachable` in `runOneMove`:**
- `.macro_translate` — comment: "used only in runSaHierarchical"
- `.macro_transform` — comment: "used only in runSaHierarchical"
These are never actually dispatched from `runSaHierarchical` either — the hierarchical SA calls `runSa` recursively rather than dispatching macro moves through the single-move interface. The move types exist in the enum but are effectively dead.

**Not wired:**
- Post-SA `insertDummies` is only estimated (dummy_count from edge counting), not actually called — `SaResult.dummy_count` is an estimate, not the result of actual insertion.
- `SaResult.guard_ring_results` allocated but the caller (`spout_run_sa_placement`) discards the result with `_ = result`.

### `placer/rudy.zig`

**Implemented:**
- `RudyGrid.init/deinit`
- `computeFull` — full RUDY computation over all nets
- `updateIncremental` — incremental update for moved devices
- `totalOverflow` — Σ max(0, demand - capacity)

No stubs or TODOs found.

### `placer/tests.zig`

**Coverage:**
- CostFunction.computeFull with various weight combinations
- Symmetry, matching, overlap, proximity, isolation, RUDY cost terms
- Orientation mismatch, LDE, common-centroid, parasitic, interdigitation, WPE
- SA convergence tests (reduce cost for constrained placements)
- Hierarchical SA fallback and macro path
- Tests exist for most implemented features

**Missing tests:**
- No test for `insertDummies` (post-SA step)
- No test for `checkGuardRings` with actual geometry
- No end-to-end test through `spout_run_sa_placement` FFI path

### `constraint/extract.zig`

**Implemented:**
- `extractConstraints` — O(n²) pair iteration with pattern matching
- `isSeedPair` — differential pair detection (same type, same W/L, shared source, different gates)
- `findLoadPair` — symmetric load pair on drain nets
- `findCascodePair` — cascode stack detection
- `findTailBias` — self-symmetric tail bias detection
- `isCurrentMirror1to1` / `isCurrentMirrorRatio` — mirror detection
- `checkPassivePair` — R/C passive matching
- `isCascode` — single cascode relation
- `addConstraintsFromML` — binary blob parser for ML augmentation

**Missing / unconnected:**
- No `isolation` constraints emitted — the `.isolation` type exists in the enum and cost function but `extractConstraints` never emits one. Isolation constraints can only come from ML augmentation.
- No `symmetry_y`, `orientation_match`, `common_centroid`, or `interdigitation` constraints emitted by the extractor — these are plan-level types with no extraction logic yet.
- Extracted `axis` values are `std.math.nan(f32)` — the SA axis is set by constraint.axis_x in cost.zig but nan propagates if never overwritten; in practice symmetry cost is computed with `axis_x = NaN` → `cost.zig computeSymmetry` produces NaN costs for any symmetry constraint coming through the default pipeline.

**Note on NaN axis:** The SA does not update `axis_x` after placement. The axis value is whatever was in the constraint at SA start. Since `extractConstraints` sets it to NaN, every symmetry constraint in the real pipeline has `axis_x = NaN`, and `computeSymmetry` produces NaN for those constraints. The NaN propagates into the combined cost and makes the Metropolis criterion undefined. This is a latent correctness bug.

### `constraint/tests.zig`

**Coverage:**
- Differential pair → symmetry (1 constraint)
- Current mirror 1:1 and ratio → matching
- Cascode → proximity
- Passive R/C pair → matching
- Multi-topology circuit combining the above
- Tail bias detection
- ML augmentation write-back
- Weight values for each constraint type

**Well tested** relative to what is implemented.

### `constraint/patterns.zig`

Pattern helper functions (packPair, drainNet, sourceNet, gateNet, etc.). All utility; no stubs found.

### `characterize/lib.zig`, `drc.zig`, `lvs.zig`, `pex.zig`, `ext2spice.zig`, `types.zig`

**Status per TODO.md:** "This is fully vibe-coded here... Not functional, so we use magic/klayout as dependencies."

The characterize/ subsystem is imported in `src/lib.zig` and re-exported as `pub const characterize`. The `SpoutContext` struct has `drc_violations`, `lvs_report`, and `pex_result` fields. The functions `spout_run_drc`, `spout_run_lvs`, `spout_run_pex` exist in lib.zig and call the Zig characterize functions.

However, the **Python pipeline never calls these**. All signoff is done via external KLayout (`run_klayout_drc`, `run_klayout_lvs`) and Magic (`run_magic_pex`) subprocesses in `python/tools.py`. The in-engine characterize subsystem is structurally present but functionally bypassed.

### `liberty/lib.zig`, `types.zig`, `writer.zig`, `spice_sim.zig`, `gds_area.zig`, `pdk.zig`

**Implemented:**
- Full Liberty file generation from GDS area + SPICE netlist + ngspice simulation
- NLDM 2D tables (configurable NxM)
- Multi-corner support via `CornerSpec`
- `pg_pin` groups, `related_power_pin`, timing arcs
- `lu_table_template` definitions
- `PdkCornerSet` for sky130 and gf180mcu with hardcoded comptime data

**Specced but unimplemented (per `liberty/TODO.md`):**
- Volare PDK directory structure auto-discovery
- `LibertyConfig.fromVolare(pdk_root, pdk_name, corner_name)` constructor
- `$PDK_ROOT` / `$PDK` env var support
- ADC Liberty validation test

**Not connected to placer:**
- Liberty/timing data is never read by the SA cost function. There is no timing-aware placement. The `w_timing` field in Python `SaConfig` and `wTiming` in `_SaConfigC` have no corresponding field in the Zig `SaConfig` extern struct.

---

## TODO Inventory

| File | Line | Comment |
|---|---|---|
| `src/lib.zig` | 639 | `// Placeholder — ML constraint write-back not yet implemented.` |
| `src/lib.zig` | 1040 | `// Placeholder — gradient refinement not yet implemented.` |
| `src/lib.zig` | 472 | `// is_power: sa.zig has no power-net info yet` (comment in runSa call) |
| `src/placer/sa.zig` | 745 | `.macro_translate => unreachable, // used only in runSaHierarchical` |
| `src/placer/sa.zig` | 746 | `.macro_transform => unreachable, // used only in runSaHierarchical` |
| `src/placer/cost.zig` | 1015–1016 | `_ = layout_width; _ = layout_height;` in `countExposedEdges` — boundary detection suppressed |
| `src/liberty/TODO.md` | all | Volare PDK auto-discovery, `LibertyConfig.fromVolare`, ADC validation test |
| `src/characterize/TODO.md` | 1 | "This is fully vibe-coded here... Not functional" |

---

## Constraint System Status

| Constraint | Specced in ARCH/IMPL | Enum defined | Logic implemented | Emitted by extractor | Enforced during SA | Tested |
|---|---|---|---|---|---|---|
| `symmetry` (X-axis) | Yes | Yes | Yes | Yes | Yes (axis=NaN bug) | Yes |
| `matching` | Yes | Yes | Yes | Yes | Yes | Yes |
| `proximity` | Yes | Yes | Yes | Yes (cascode) | Yes | Yes |
| `isolation` | Yes | Yes | Yes | **No** — never emitted | Yes (if externally set) | Partial |
| `symmetry_y` | Yes | Yes | Yes | **No** | Yes (if externally set) | Partial (tests exist in cost) |
| `orientation_match` | Yes (Phase 2) | Yes | Yes | **No** | Yes (if externally set) | Yes (cost tests) |
| `common_centroid` | Yes (Phase 3) | Yes | Yes (via CentroidGroup sidecar) | **No** | **No** — extended input always empty | Yes (cost tests) |
| `interdigitation` | Yes (Phase 7) | Yes | Yes (via CentroidGroup sidecar) | **No** | **No** — extended input always empty | Yes (cost tests) |

**Key finding:** The four constraint types in ARCH.md that were originally described as "dead" (`proximity`, `isolation`) are now implemented in the cost function. However, `isolation` is never emitted by the extractor, and `common_centroid`/`interdigitation` require the extended input mechanism that is never populated from the main pipeline.

---

## Placer → Router Handoff

### What the router needs

The detailed router (`router/detailed.zig`) reads:
- `ctx.devices.positions` — device origin coordinates (GDSII gate-channel origin)
- `ctx.devices.types` / `ctx.devices.params` — device geometry
- `ctx.nets` — net fanout and is_power flags
- `ctx.pins` — device/net/terminal associations and positions
- `ctx.adj` — CSR adjacency

### What the placer produces

- `ctx.devices.positions` — **updated in-place** by SA, then shifted back from centre-space to origin-space
- All other arrays — **unchanged** by placement

### What is missing or wrong

1. **Pin positions not written back.** During SA, `pin_positions` is a scratch buffer local to `spout_run_sa_placement`. After SA, the scratch buffer is freed. `ctx.pins.position` is never updated to reflect post-SA device positions. The router uses stale `ctx.pins.position` values (whatever was computed by `computePinOffsets` at parse time — all relative to position 0,0). This means routing uses pin positions from the pre-placement origin, not post-placement positions.

2. **Orientation not written back.** SA internally maintains an `orientations[]` scratch buffer. After SA, the final device orientations are not written to `ctx.devices.orientations`. The router does not see orientation changes.

3. **Dummy devices not inserted.** `SaResult.dummy_count` is an estimate; `insertDummies` is never called. No dummy devices appear in the GDSII output.

4. **Guard ring results discarded.** `SaResult.guard_ring_results` allocated inside SA is thrown away by `_ = result` in lib.zig.

5. **Extended inputs never fed.** The router has no access to centroid_groups, heat_sources, or well_regions — but those are placer-side inputs. The key missing piece is that centroid groups and interdigitation groups derived from circuit analysis are never computed anywhere in the pipeline; there is no stage that produces `CentroidGroup[]` from the netlist.

---

## Characterization Integration

### What TODO.md says

"This is fully vibe-coded here... Not functional, so we use magic/klayout as dependencies."

### What code exists

The `characterize/` directory contains complete Zig implementations of:
- `drc.zig` — `runDrc`, `runDrcOnSlices`
- `lvs.zig` — `UnionFind`, `LvsChecker.compareDeviceLists`
- `pex.zig` — `extractFromRoutes`
- `ext2spice.zig` — `SpiceWriter`
- `types.zig` — all data types

`lib.zig` exports all of these and includes all sub-modules in `comptime` block.

`src/lib.zig` exports `pub const characterize` and `SpoutContext` has result fields. The functions `spout_run_drc`, `spout_run_lvs`, `spout_run_pex` call the Zig implementations.

### Is it called from the main flow?

**No.** `python/main.py` calls:
- `run_klayout_drc` (subprocess: `klayout -b -r sky130A.lydrc ...`)
- `run_klayout_lvs` (subprocess: `klayout -b -r ...`)
- `run_magic_pex` (subprocess: `magic -rcfile ...`)

The in-engine characterize functions are never invoked from Python. They exist and compile but are dead at runtime.

### What is needed to make it functional

1. Replace or supplement `run_klayout_drc` with `layout.run_drc()` → `spout_run_drc` in the Python pipeline
2. Validate that `runDrc` produces equivalent results to KLayout for sky130 rule set
3. Same for LVS and PEX

---

## Critical Path to a Working Placer

The following are ordered by dependency. Items earlier in the list block items later.

### P0 — Fix Python ABI struct mismatch (blocks all weight tuning)

`python/config.py:_SaConfigC` must exactly mirror the Zig `SaConfig` extern struct field-for-field. Currently the Python struct has phantom fields (`wTiming`, `wEmbedSimilarity`, `adaptiveCooling`, `adaptiveWindow`, etc.) that don't exist in Zig. The `sizeof` mismatch causes `spout_run_sa_placement` to silently use default weights for every run. Fix: regenerate `_SaConfigC` from `SaConfig` field-by-field.

### P0 — Fix NaN symmetry axis (blocks symmetry constraint correctness)

`constraint/extract.zig` sets `axis = std.math.nan(f32)` for all symmetry constraints because the axis cannot be known before placement. The axis must be initialized to the centroid X of the constrained pair's initial positions before SA starts, or the cost function must handle NaN gracefully. Currently NaN propagates through `computeSymmetry` and corrupts the total cost, making Metropolis acceptance undefined for any circuit with a differential pair.

Fix options:
- After initial greedy placement in `runSa`, recompute symmetry axes as midpoints between constrained pairs and store back into the constraint list.
- Or initialize `axis_x` in `spout_run_sa_placement` before calling `runSa`.

### P0 — Write pin positions back after SA (blocks correct routing)

After `sa.runSa` returns, update `ctx.pins.position[i]` for each pin using the final `device_positions + pin_offsets`. Currently the router receives pre-placement pin positions.

### P1 — Populate extended SA inputs (blocks advanced constraints)

`spout_run_sa_placement` always passes `extended: .{}`. To use common-centroid and interdigitation cost terms, build `CentroidGroup[]` slices from the constraint arrays (where `kind == .common_centroid` / `.interdigitation`) before calling `runSa`, and pass them in `SaExtendedInput`.

### P1 — Emit isolation constraints from extractor (blocks analog-digital separation)

`constraint/extract.zig` never emits `.isolation`. Implement detection logic (e.g., NMOS devices whose drain nets connect to power nets should be isolated from matched analog devices).

### P1 — Initialize symmetry axis in constraint-aware grouping (enables correct SA restarts)

Implement a pre-pass that sets `axis_x` / `axis_y` for each symmetry constraint to the geometric midpoint of the constrained pair after initial placement.

### P2 — Write orientations back after SA

Copy the SA's internal `orientations[]` buffer back to `ctx.devices.orientations` after `runSa` returns, so the GDSII writer can place devices with correct orientations.

### P2 — Call `insertDummies` post-SA (enables edge-effect protection)

`insertDummies` is implemented but never called. Call it after SA converges, before pin writeback and routing, passing the matched device positions.

### P2 — Emit `common_centroid` / `interdigitation` from extractor (enables gradient cancellation)

Implement pattern recognition for multi-unit-cell arrays (ABBA / ABAB patterns) in `constraint/extract.zig` and emit the corresponding constraint types.

### P3 — Connect Liberty timing to placer cost (enables timing-aware placement)

Currently `w_timing` in the Python SaConfig has no Zig counterpart. A timing-aware placement would require: run Liberty characterization → extract cell delay estimates → add timing-driven HPWL weighting to the SA cost function.

### P3 — Activate in-engine characterize subsystem (replaces external tool dependency)

Replace `run_klayout_drc` / `run_klayout_lvs` / `run_magic_pex` calls with `layout.run_drc()` etc., contingent on the in-engine implementations producing correct results.

---

## SVG — Placer Subsystem Completion

```svg
<svg viewBox="0 0 1000 700" xmlns="http://www.w3.org/2000/svg" font-family="monospace" font-size="11">
  <!-- Background -->
  <rect width="1000" height="700" fill="#060C18"/>

  <!-- Legend -->
  <rect x="720" y="20" width="260" height="120" rx="6" fill="#0d1a2e" stroke="#1e3a5f" stroke-width="1"/>
  <text x="730" y="38" fill="#B8D0E8" font-size="12" font-weight="bold">Legend</text>
  <rect x="730" y="46" width="14" height="14" rx="2" fill="#1a6b3a"/>
  <text x="750" y="58" fill="#B8D0E8">Implemented</text>
  <rect x="730" y="66" width="14" height="14" rx="2" fill="#8b6914"/>
  <text x="750" y="78" fill="#B8D0E8">Partial / Wired but gapped</text>
  <rect x="730" y="86" width="14" height="14" rx="2" fill="#6b1a1a"/>
  <text x="750" y="98" fill="#B8D0E8">Stub / Missing</text>
  <rect x="730" y="106" width="14" height="14" rx="2" fill="#1e3a5f"/>
  <text x="750" y="118" fill="#B8D0E8">Implemented, not wired</text>
  <!-- Arrow legend -->
  <line x1="730" y1="128" x2="760" y2="128" stroke="#00C4E8" stroke-width="2"/>
  <text x="768" y="132" fill="#B8D0E8">Data flow (working)</text>

  <!-- Title -->
  <text x="20" y="30" fill="#00C4E8" font-size="16" font-weight="bold">Spout Placer — Subsystem Completion</text>

  <!-- Row 1: Inputs -->
  <!-- PDK box -->
  <rect x="20" y="55" width="110" height="44" rx="5" fill="#1a6b3a" stroke="#00C4E8" stroke-width="1.5"/>
  <text x="75" y="73" fill="#B8D0E8" text-anchor="middle" font-size="11">PDK</text>
  <text x="75" y="88" fill="#B8D0E8" text-anchor="middle" font-size="10">Device dims</text>

  <!-- Liberty/Char box -->
  <rect x="20" y="115" width="110" height="44" rx="5" fill="#1e3a5f" stroke="#444" stroke-width="1.5" stroke-dasharray="4,3"/>
  <text x="75" y="133" fill="#B8D0E8" text-anchor="middle" font-size="11">Liberty/Char</text>
  <text x="75" y="148" fill="#9ab0c0" text-anchor="middle" font-size="10">Timing (not wired)</text>

  <!-- Python API -->
  <rect x="160" y="55" width="120" height="44" rx="5" fill="#1a6b3a" stroke="#00C4E8" stroke-width="1.5"/>
  <text x="220" y="73" fill="#B8D0E8" text-anchor="middle" font-size="11">Python API</text>
  <text x="220" y="88" fill="#B8D0E8" text-anchor="middle" font-size="10">run_pipeline()</text>

  <!-- Arrows from inputs -->
  <line x1="130" y1="77" x2="158" y2="77" stroke="#00C4E8" stroke-width="2" marker-end="url(#arr)"/>
  <line x1="75" y1="99" x2="75" y2="295" stroke="#444" stroke-width="1.5" stroke-dasharray="5,4"/>

  <!-- Row 2: Parse + Constraint -->
  <rect x="160" y="130" width="120" height="44" rx="5" fill="#1a6b3a" stroke="#00C4E8" stroke-width="1.5"/>
  <text x="220" y="148" fill="#B8D0E8" text-anchor="middle" font-size="11">Parse Netlist</text>
  <text x="220" y="163" fill="#B8D0E8" text-anchor="middle" font-size="10">spout_parse_netlist</text>

  <rect x="310" y="130" width="130" height="44" rx="5" fill="#1a6b3a" stroke="#00C4E8" stroke-width="1.5"/>
  <text x="375" y="148" fill="#B8D0E8" text-anchor="middle" font-size="11">Constraint Extractor</text>
  <text x="375" y="163" fill="#9ab0c0" text-anchor="middle" font-size="10">sym/match/prox only</text>

  <!-- Vertical flow arrows left column -->
  <line x1="220" y1="99" x2="220" y2="128" stroke="#00C4E8" stroke-width="2" marker-end="url(#arr)"/>
  <line x1="280" y1="152" x2="308" y2="152" stroke="#00C4E8" stroke-width="2" marker-end="url(#arr)"/>

  <!-- Row 3: Clustering / Floorplan (not in current system — stub) -->
  <rect x="460" y="130" width="120" height="44" rx="5" fill="#6b1a1a" stroke="#c44" stroke-width="1.5"/>
  <text x="520" y="148" fill="#B8D0E8" text-anchor="middle" font-size="11">Clustering</text>
  <text x="520" y="163" fill="#9ab0c0" text-anchor="middle" font-size="10">Missing</text>

  <rect x="600" y="130" width="110" height="44" rx="5" fill="#6b1a1a" stroke="#c44" stroke-width="1.5"/>
  <text x="655" y="148" fill="#B8D0E8" text-anchor="middle" font-size="11">Floorplan</text>
  <text x="655" y="163" fill="#9ab0c0" text-anchor="middle" font-size="10">Missing</text>

  <line x1="440" y1="152" x2="458" y2="152" stroke="#444" stroke-width="1.5" stroke-dasharray="5,4"/>
  <line x1="580" y1="152" x2="598" y2="152" stroke="#444" stroke-width="1.5" stroke-dasharray="5,4"/>

  <!-- Row 4: SA placement -->
  <rect x="160" y="215" width="280" height="54" rx="5" fill="#1a6b3a" stroke="#00C4E8" stroke-width="1.5"/>
  <text x="300" y="235" fill="#B8D0E8" text-anchor="middle" font-size="12" font-weight="bold">SA Placement Engine</text>
  <text x="300" y="252" fill="#B8D0E8" text-anchor="middle" font-size="10">sa.runSa / runSaHierarchical</text>
  <text x="300" y="265" fill="#9ab0c0" text-anchor="middle" font-size="10">16-term cost, 4 move types</text>

  <!-- Constraint → SA -->
  <line x1="375" y1="174" x2="375" y2="213" stroke="#00C4E8" stroke-width="2" marker-end="url(#arr)"/>
  <line x1="220" y1="174" x2="220" y2="213" stroke="#00C4E8" stroke-width="2" marker-end="url(#arr)"/>

  <!-- Extended inputs to SA (dashed - not wired) -->
  <rect x="460" y="215" width="130" height="54" rx="5" fill="#6b1a1a" stroke="#c44" stroke-width="1.5" stroke-dasharray="4,3"/>
  <text x="525" y="235" fill="#B8D0E8" text-anchor="middle" font-size="11">Extended Inputs</text>
  <text x="525" y="250" fill="#9ab0c0" text-anchor="middle" font-size="10">CentroidGroups</text>
  <text x="525" y="263" fill="#9ab0c0" text-anchor="middle" font-size="10">HeatSources/Wells</text>
  <line x1="460" y1="242" x2="443" y2="242" stroke="#c44" stroke-width="1.5" stroke-dasharray="5,4"/>

  <!-- ABI mismatch warning -->
  <rect x="600" y="215" width="110" height="54" rx="5" fill="#6b1a1a" stroke="#c44" stroke-width="1.5"/>
  <text x="655" y="235" fill="#ff7070" text-anchor="middle" font-size="11">ABI Mismatch</text>
  <text x="655" y="252" fill="#9ab0c0" text-anchor="middle" font-size="10">Python SaConfig</text>
  <text x="655" y="265" fill="#9ab0c0" text-anchor="middle" font-size="10">≠ Zig SaConfig</text>

  <!-- Row 5: Legalization + SA Refine -->
  <rect x="160" y="300" width="120" height="44" rx="5" fill="#6b1a1a" stroke="#c44" stroke-width="1.5"/>
  <text x="220" y="318" fill="#B8D0E8" text-anchor="middle" font-size="11">Legalization</text>
  <text x="220" y="333" fill="#9ab0c0" text-anchor="middle" font-size="10">Missing</text>

  <rect x="310" y="300" width="130" height="44" rx="5" fill="#8b6914" stroke="#c8a400" stroke-width="1.5"/>
  <text x="375" y="318" fill="#B8D0E8" text-anchor="middle" font-size="11">Post-SA Steps</text>
  <text x="375" y="333" fill="#9ab0c0" text-anchor="middle" font-size="10">Dummies (est only)</text>

  <!-- SA → these -->
  <line x1="220" y1="269" x2="220" y2="298" stroke="#444" stroke-width="1.5" stroke-dasharray="5,4"/>
  <line x1="300" y1="269" x2="375" y2="298" stroke="#c8a400" stroke-width="1.5" stroke-dasharray="3,2"/>

  <!-- Row 6: Output -->
  <rect x="160" y="375" width="280" height="44" rx="5" fill="#1a6b3a" stroke="#00C4E8" stroke-width="1.5"/>
  <text x="300" y="393" fill="#B8D0E8" text-anchor="middle" font-size="11">Placed Output</text>
  <text x="300" y="408" fill="#9ab0c0" text-anchor="middle" font-size="10">ctx.devices.positions updated</text>

  <line x1="375" y1="344" x2="375" y2="373" stroke="#c8a400" stroke-width="1.5" stroke-dasharray="3,2"/>
  <line x1="300" y1="344" x2="300" y2="373" stroke="#444" stroke-width="1.5" stroke-dasharray="5,4"/>
  <line x1="300" y1="269" x2="300" y2="373" stroke="#00C4E8" stroke-width="2" marker-end="url(#arr)"/>

  <!-- Row 7: Router handoff -->
  <rect x="160" y="450" width="280" height="54" rx="5" fill="#8b6914" stroke="#c8a400" stroke-width="1.5"/>
  <text x="300" y="470" fill="#B8D0E8" text-anchor="middle" font-size="12" font-weight="bold">Router Handoff</text>
  <text x="300" y="487" fill="#c8a400" text-anchor="middle" font-size="10">positions OK, pin pos stale</text>
  <text x="300" y="500" fill="#9ab0c0" text-anchor="middle" font-size="10">orientations not written back</text>

  <line x1="300" y1="419" x2="300" y2="448" stroke="#c8a400" stroke-width="2" marker-end="url(#arry)"/>

  <!-- Row 8: Detailed Router + GDSII -->
  <rect x="160" y="535" width="120" height="44" rx="5" fill="#1a6b3a" stroke="#00C4E8" stroke-width="1.5"/>
  <text x="220" y="553" fill="#B8D0E8" text-anchor="middle" font-size="11">Detailed Router</text>
  <text x="220" y="568" fill="#B8D0E8" text-anchor="middle" font-size="10">routeAll / RipUp</text>

  <rect x="310" y="535" width="130" height="44" rx="5" fill="#1a6b3a" stroke="#00C4E8" stroke-width="1.5"/>
  <text x="375" y="553" fill="#B8D0E8" text-anchor="middle" font-size="11">GDSII Export</text>
  <text x="375" y="568" fill="#B8D0E8" text-anchor="middle" font-size="10">spout_export_gdsii</text>

  <line x1="220" y1="504" x2="220" y2="533" stroke="#c8a400" stroke-width="2" marker-end="url(#arry)"/>
  <line x1="280" y1="557" x2="308" y2="557" stroke="#00C4E8" stroke-width="2" marker-end="url(#arr)"/>

  <!-- Characterize block (side) -->
  <rect x="460" y="450" width="120" height="54" rx="5" fill="#1e3a5f" stroke="#444" stroke-width="1.5" stroke-dasharray="4,3"/>
  <text x="520" y="470" fill="#B8D0E8" text-anchor="middle" font-size="11">Characterize</text>
  <text x="520" y="487" fill="#9ab0c0" text-anchor="middle" font-size="10">DRC/LVS/PEX</text>
  <text x="520" y="500" fill="#9ab0c0" text-anchor="middle" font-size="10">Impl, not wired</text>
  <line x1="440" y1="557" x2="458" y2="500" stroke="#444" stroke-width="1.5" stroke-dasharray="5,4"/>

  <!-- Signoff (external) -->
  <rect x="600" y="535" width="110" height="44" rx="5" fill="#1a6b3a" stroke="#00C4E8" stroke-width="1.5"/>
  <text x="655" y="553" fill="#B8D0E8" text-anchor="middle" font-size="11">KLayout / Magic</text>
  <text x="655" y="568" fill="#9ab0c0" text-anchor="middle" font-size="10">Signoff (external)</text>
  <line x1="440" y1="557" x2="598" y2="557" stroke="#00C4E8" stroke-width="2" marker-end="url(#arr)"/>

  <!-- Defs: arrowheads -->
  <defs>
    <marker id="arr" markerWidth="7" markerHeight="7" refX="6" refY="3.5" orient="auto">
      <polygon points="0 0, 7 3.5, 0 7" fill="#00C4E8"/>
    </marker>
    <marker id="arry" markerWidth="7" markerHeight="7" refX="6" refY="3.5" orient="auto">
      <polygon points="0 0, 7 3.5, 0 7" fill="#c8a400"/>
    </marker>
  </defs>

  <!-- Critical bug annotations -->
  <text x="20" y="640" fill="#ff7070" font-size="11">CRITICAL: Python ABI struct mismatch — SA always runs with default weights</text>
  <text x="20" y="658" fill="#ff7070" font-size="11">CRITICAL: Symmetry axis = NaN from extractor — symmetry cost is NaN in production</text>
  <text x="20" y="676" fill="#c8a400" font-size="11">WARNING: Pin positions not written back after SA — router uses pre-placement pins</text>
</svg>
```

---

## Appendix: Field-by-Field ABI Mismatch

Python `_SaConfigC` fields that **do not exist** in Zig `SaConfig`:

| Python field | Zig equivalent |
|---|---|
| `wTiming` | None — no timing cost term in Zig SA |
| `wEmbedSimilarity` | None |
| `adaptiveCooling` (u8) | None — Zig has `kappa` for schedule type |
| `adaptiveWindow` (u32) | None |
| `reheatFraction` (f32) | None — Zig uses ratio `< 0.02` hardcoded |
| `stallWindowsBeforeReheat` (u32) | None |
| `numStarts` (u32) | None |
| `delayDriverR` (f32) | None |
| `delayWireRPerUm` (f32) | None |
| `delayWireCPerUm` (f32) | None |
| `delayPinC` (f32) | None |

Zig `SaConfig` fields that **do not exist** in Python `_SaConfigC`:

| Zig field | Python equivalent |
|---|---|
| `kappa` | None |
| `max_reheats` | `maxReheats` (name match but position differs) |
| `p_macro_translate` | None |
| `p_macro_transform` | None |
| `hpwl_ratio_phase1b` | None |
| `w_proximity` | None |
| `w_isolation` | None |
| `p_orientation_flip` | None |
| `w_orientation` | None |
| `w_lde` | None |
| `w_common_centroid` | None |
| `p_group_translate` | None |
| `w_parasitic` | Partial (`wParasitic` exists but at wrong byte offset) |
| `w_interdigitation` | None |
| `w_edge_penalty` | None |
| `w_wpe` | None |
| `template_x_min/y_min/x_max/y_max` | None |
| `use_template_bounds` | None |

The structures have incompatible layouts. The `sizeof` check in `spout_run_sa_placement` will fail to match, and all SA runs use hardcoded Zig default values.
