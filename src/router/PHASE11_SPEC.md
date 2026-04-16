# Phase 11: Integration + Signoff — Specification

## Overview

Integrate analog routing (pex_feedback + parallel_router) with the existing digital DetailedRouter, expose `AnalogRouter` as the primary API, and validate with end-to-end test circuits.

## Integration Architecture

```
analog route → pex feedback loop → parallel dispatch → commit routes
                                                         ↓
detailed route (digital nets) ← analog routes merged into RouteArrays
```

### `AnalogRouter` (new public API in `lib.zig`)

```zig
pub const AnalogRouter = struct {
    allocator:     std.mem.Allocator,
    pdk:           *const PdkConfig,
    die_bbox:      Rect,
    analog_groups: AnalogGroupDB,
    pex_cfg:      PexConfig,
    num_threads:   u8,
    max_pex_iter:  u8,

    pub fn init(allocator: std.mem.Allocator, pdk, die_bbox, num_threads) !AnalogRouter
    pub fn addGroup(self: *AnalogRouter, group: AnalogGroup) !void
    pub fn routeAll(self: *AnalogRouter) !AnalogRoutingResult
    pub fn getRoutes(self: *const AnalogRouter) *const RouteArrays
    pub fn deinit(self: *AnalogRouter) void
};
```

### `AnalogRoutingResult`

```zig
pub const AnalogRoutingResult = struct {
    routes:          RouteArrays,
    match_reports:  MatchReportDB,
    iterations:     u8,
    drc_violations: []DrcViolation,
    pass:           bool,

    pub fn deinit(self: *AnalogRoutingResult) void
};
```

## Modified `detailed.zig`

Add analog routing path before digital routing:

```zig
pub fn routeAll(self: *DetailedRouter, ...) !void {
    // NEW: Run analog router first (gets matching segments committed)
    if (self.analog_router) |ar| {
        try ar.routeAll()
        try self.mergeAnalogRoutes(ar.getRoutes())
    }

    // EXISTING: Route remaining (digital) nets
    try self.routeDigitalNets(...)
}
```

## Modified `lib.zig`

```zig
pub const AnalogRouter = @import("analog_router.zig").AnalogRouter;
pub const MatchReportDB = @import("pex_feedback.zig").MatchReportDB;
pub const ThreadPool = @import("thread_pool.zig").ThreadPool;
pub const PexFeedbackLoop = @import("pex_feedback.zig").PexFeedbackLoop;
```

## End-to-End Test Circuits

### Test 1: Differential Pair (`test_e2e_diff_pair`)

- 2 NMOS devices with shared gate, drain currents matched
- Constraint: <1% length mismatch, via count delta ≤ 1
- Expectation: zero DRC, R_ratio < 0.05, C_ratio < 0.05

### Test 2: Current Mirror (`test_e2e_current_mirror`)

- 4 matched PMOS devices in current mirror
- Constraint: <5% R matching across all legs
- Expectation: passes tolerance after ≤5 PEX iterations

### Test 3: Kelvin Force/Sense (`test_e2e_kelvin`)

- Force and sense nets routed separately (no shared segments)
- Constraint: force path has lowest R; sense path has no resistive drop
- Expectation: force and sense segments are geometrically disjoint

## Exit Criteria

1. All analog groups pass tolerance after ≤5 PEX iterations, OR report best-effort with failure reason
2. Zero DRC violations in analog routes
3. All test circuits pass with `zig build test`
4. `AnalogRouter` exports via `lib.zig` as the primary API

## Dependencies

- `src/router/pex_feedback.zig` — Phase 9 PEX feedback
- `src/router/thread_pool.zig` — Phase 10 thread pool
- `src/router/parallel_router.zig` — Phase 10 parallel dispatch
- `src/router/detailed.zig` — integration point
- `src/router/lib.zig` — public API export
