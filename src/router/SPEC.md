# Phase 4: Matched Router — Specification

## Overview

Phase 4 implements symmetric/matched routing for analog circuits: differential pairs, current mirrors, and other nets requiring parasitic-aware routing. The implementation builds on the multi-layer grid and A* router from earlier phases.

## New Types

### AnalogGroupType
```zig
pub const AnalogGroupType = enum(u8) {
    differential = 0,  // 2 nets, opposite phase
    matched = 1,        // 2+ nets, same phase, tolerance-based
    shielded = 2,       // Signal net + shield net
    kelvin = 3,        // Force + sense pair
    resistor = 4,       // Resistor matched group
    capacitor = 5,      // Capacitor matched array
};
```

### AnalogGroupIdx
```zig
pub const AnalogGroupIdx = enum(u32) {
    _,
    pub inline fn toInt(self: AnalogGroupIdx) u32 { return @intFromEnum(self); }
    pub inline fn fromInt(v: u32) AnalogGroupIdx { return @enumFromInt(v); }
};
```

## SymmetricSteiner Tree

Generates mirror-image Steiner trees for paired nets (p/n of a differential pair) around a shared centroid axis.

### Fields
- `pins_p: []const Pin` — positive-net pin positions `[x, y]`
- `pins_n: []const Pin` — negative-net pin positions `[x, y]`
- `axis: Axis` — `.x` or `.y` — mirror axis
- `axis_value: f32` — coordinate value of the axis
- `edges_p: []Segment` — Steiner tree segments for net P
- `edges_n: []Segment` — Steiner tree segments for net N (mirror of P)

### Segment
```zig
pub const Segment = struct {
    x1: f32, y1: f32, x2: f32, y2: f32,
    pub fn length(self: Segment) f32 { ... }
};
```

### Methods
- `build()` — compute symmetric Steiner tree from pins_p, pins_n, axis
- `mirror()` — reflect tree around centroid axis
- `centroidAxis()` — compute shared centroid axis for paired nets
- `totalLength(side: Side) f32` — total wirelength for P or N side
- `deinit()` — free allocated edge arrays

## MatchedRouter

Wraps AStarRouter + AnalogRouteDB to route matched net groups with balancing.

### MatchedRoutingCost Callback
```zig
pub const MatchedRoutingCost = struct {
    base_cost: f32,        // Standard A* movement cost
    mismatch_penalty: f32, // Wire-length mismatch penalty
    via_penalty: f32,      // Per-via penalty for balancing
    same_layer_bonus: f32, // Reward for staying on same layer
};
```

### Fields
- `allocator: std.mem.Allocator`
- `astar: AStarRouter`
- `cost_fn: MatchedRoutingCost`
- `segments_p: std.ArrayList(Segment)` — routed segments for net P
- `segments_n: std.ArrayList(Segment)` — routed segments for net N
- `via_counts: [2]u32` — via counts [net_p, net_n]
- `preferred_layer: u8`

### Methods
- `init()` — create MatchedRouter
- `deinit()` — free all memory
- `routeGroup()` — route a differential/matched group using A*
- `balanceWireLengths()` — add jogs to shorter net to match longer
- `balanceViaCounts()` — add dummy vias to net with fewer vias
- `sameLayerEnforcement()` — force all segments onto preferred_layer
- `netLength(net: NetIdx) f32` — total routed length for a net
- `viaCount(net: NetIdx) u32` — total vias for a net

### routeGroup Algorithm
1. Build SymmetricSteiner tree for the group
2. For each Steiner edge, find path using AStarRouter.findPath()
3. Apply MatchedRoutingCost: penalize length mismatch, layer differences
4. Collect all path segments into segments_p / segments_n
5. Compute via counts from layer transitions

### balanceWireLengths Algorithm
1. Compute totalLength for each net
2. Compute delta = len_p - len_n
3. If delta > tolerance * max(len_p, len_n):
   - Find longest silent (same-net) segment on shorter net
   - Add jog (L-shaped detour) to that segment
   - Repeat until ratio < tolerance

### balanceViaCounts Algorithm
1. Count vias on each net from layer transitions
2. If delta > 1:
   - Find DRC-clean silent segment on net with fewer vias
   - Add dummy via pair (down + up) marking via_count
   - DRC-skip if spacing violation would result

## A* MatchedCostFn Extension

Modify `astar.zig` `findPath()` to accept an optional `MatchedCostFn`:

```zig
pub const MatchedCostFn = struct {
    net: NetIdx,           // Current net being routed
    partner_net: NetIdx,   // The paired net (for mismatch cost)
    partner_path: ?[]const GridNode, // Partner's routed path (for mismatch calc)
    mismatch_penalty: f32,
    via_penalty: f32,
    same_layer_bonus: f32,
    preferred_layer: u8,
};
```

The matched findPath variant adds:
- Layer-change cost when partner is on different layer
- Mismatch cost when current position diverges from partner's path
- Same-layer bonus when staying on preferred_layer

## Tests (Section 4 from GUIDE_04_TESTING_STRATEGY.md)

| Test | Description |
|------|-------------|
| 4.1.1 | SymmetricSteiner mirrors correctly |
| 4.2.1 | Wire-length balancing adds jogs |
| 4.2.2 | Wire-length balancing skips when matched |
| 4.3.1 | Via count balancing adds dummy vias |
| 4.3.2 | Via count balancing skips DRC-violating locations |
| 4.4.1 | Matched nets routed on same metal layer |
| 4.5.1 | Single-pin nets handled gracefully |
| 4.5.2 | Coincident pins produce zero-length route |
| 4.5.3 | Unequal pin count uses virtual pin |

## Exit Criteria

- Differential pair routes with <1% length mismatch
- Via count delta <= 1
- All segments on same layer for matched nets
- All tests pass under `zig build test`
