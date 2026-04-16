# Phase 9: PEX Feedback Loop — Specification

## Overview

The PEX feedback loop closes the analog matching gap by iteratively routing, extracting parasitics, computing per-group match metrics, and applying targeted repairs. Max 5 iterations.

```
route → extract → compute MatchReport → repair if needed → re-route
```

## Data Structures

### NetResult (SoA per extracted net)

```zig
pub const NetResult = struct {
    net_id:    u32,
    total_r:   f32,   // Ω — sum of all R elements on this net
    total_c:   f32,   // fF — sum of all C elements to substrate
    via_count: u32,
    seg_count: u32,
    length:    f32,   // µm — total wire length
};
```

### MatchReportDB (SoA per analog group)

```zig
pub const MatchReportDB = struct {
    // Per-group arrays (SoA)
    group_idx:    []AnalogGroupIdx,
    passes:       []bool,

    // Per-net metrics within each group
    r_ratio:      []f32,    // |R_a - R_b| / max(R_a, R_b)
    c_ratio:      []f32,    // |C_a - C_b| / max(C_a, C_b)
    length_ratio: []f32,    // |L_a - L_b| / max(L_a, L_b)
    via_delta:    []i32,    // via_count_a - via_count_b (signed)
    coupling_delta: []f32,  // fF — coupling cap difference to neighbors

    // Reference to source PexResult (not owned)
    allocator:    std.mem.Allocator,
};
```

### RepairAction (enum)

```zig
pub const RepairAction = enum {
    adjust_widths,   // R mismatch → widen/narrow wire
    adjust_layers,    // C mismatch → move to different metal layer
    add_jogs,         // length mismatch → add silent jogs
    add_dummy_vias,   // via count delta → add dummy vias
    rebalance_layer,   // coupling mismatch → re-assign layer to reduce coupling
};
```

## Functions

### `extractNet(routes, net, pex_cfg, allocator) !NetResult`

Extract parasitics for a single net by filtering `routes` to segments belonging to `net`, then computing total R, C, via count, segment count, and length. Returns `NetResult`.

### `computeMatchReport(group, net_results, tolerance) MatchReport`

For a matched group (e.g., differential pair), compute per-metric ratios:
- `r_ratio = |R_a - R_b| / max(R_a, R_b)`
- `c_ratio = |C_a - C_b| / max(C_a, C_b)`
- `length_ratio = |L_a - L_b| / max(L_a, L_b)`
- `via_delta = via_count_a - via_count_b`
- `coupling_delta` = Σ coupling caps involving group nets minus Σ for reference net

`passes = true` iff all ratios ≤ tolerance.

### `repairFromPexReport(report, routes, group) !void`

Apply targeted repairs based on failing metrics:
- **R mismatch** → adjust widths in `routes` for group nets (widen to reduce R, narrow to increase R ratio)
- **C mismatch** → adjust layers (move coupling-sensitive nets to upper metals)
- **Length mismatch** → add jogs to silent segments (segments not on critical path)
- **Via mismatch** → insert dummy vias where DRC-clean
- **Coupling mismatch** → rebalance layer assignment (prefer upper metals for high-Z nodes)

Repairs are applied in-place to the `RouteArrays`.

### `pexFeedbackLoop(routes, groups, pex_cfg, max_iterations) !PexFeedbackResult`

```
var iter = 0
while (iter < max_iterations) {
    // 1. Route all groups (delegates to existing router)
    try routeAllAnalogGroups(routes, groups)

    // 2. Extract per-net parasitics
    for (groups.nets) |net| {
        net_results[net] = try extractNet(routes, net, pex_cfg, allocator)
    }

    // 3. Compute match reports
    for (groups.items) |grp| {
        reports[grp] = try computeMatchReport(grp, net_results, grp.tolerance)
        if (reports[grp].passes) continue
        try repairFromPexReport(reports[grp], routes, grp)
    }

    // 4. Check convergence
    var all_pass = true
    for (reports.items) |rep| if (!rep.passes) { all_pass = false; break }
    if (all_pass) break
    iter += 1
}
return PexFeedbackResult{ .iterations = iter, .reports = reports }
```

## Exit Criteria

- All groups pass tolerance → success
- `iterations == max_iterations` and any group still failing → `failure_reason = .mismatch_exceeded`

## Dependencies

- `src/characterize/pex.zig` — uses `extractFromRoutes` internally
- `src/core/route_arrays.zig` — `RouteArrays` for segment storage
- `src/characterize/types.zig` — `PexConfig`, `PexResult`, `RcElement`
