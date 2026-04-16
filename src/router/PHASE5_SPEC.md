# Phase 5: Shield Router Specification

## Overview

The Shield Router generates shield wires on adjacent layers for sensitive analog nets. Shield wires are driven guards that reduce capacitive coupling by providing a grounded (or driven) reference adjacent to signal wires.

## ShieldDB SoA Table

| Field | Type | Description |
|-------|------|-------------|
| `x1` | `f32` | Shield wire start X |
| `y1` | `f32` | Shield wire start Y |
| `x2` | `f32` | Shield wire end X |
| `y2` | `f32` | Shield wire end Y |
| `width` | `f32` | Shield wire width |
| `layer` | `u8` | Shield wire metal layer |
| `shield_net` | `NetIdx` | Net connected to shield (ground or driven) |
| `signal_net` | `NetIdx` | Signal net being shielded |
| `is_driven` | `bool` | True if shield is driven (not ground) |

## ShieldRouter API

```zig
pub const ShieldRouter = struct {
    db: ShieldDB,
    allocator: std.mem.Allocator,
    pdk: *const PdkConfig,

    pub fn init(allocator: std.mem.Allocator, pdk: *const PdkConfig) !ShieldRouter
    pub fn deinit(self: *ShieldRouter) void
    pub fn routeShielded(self: *ShieldRouter, signal_net: NetIdx, shield_net: NetIdx, signal_layer: u8) !void
    pub fn routeDrivenGuard(self: *ShieldRouter, signal_net: NetIdx, guard_net: NetIdx, shield_layer: u8) !void
    pub fn getShields(self: *const ShieldRouter) []const ShieldWire
    pub fn shieldCount(self: *const ShieldRouter) u32
};
```

## Algorithm: routeShielded()

1. For each routed signal segment on `signal_layer`:
   - Compute shield rect on adjacent layer (`signal_layer + 1`, wrapping at top)
   - Expand shield by shield spacing margin
2. Query spatial index / InlineDrcChecker for conflicts on shield layer
3. Skip segments with DRC conflicts (shield continuity gap is acceptable)
4. Append DRC-clean shield segments to ShieldDB with `shield_net` = ground, `is_driven` = false
5. Shield wires are registered with the DRC checker for later via stitching

## Algorithm: routeDrivenGuard()

Same as `routeShielded()` but `shield_net` = `signal_net` (same potential), `is_driven` = true.

Used for high-impedance nodes where AC ground is needed but no DC connection to VSS exists.

## Geometry Rules

- Shield layer = signal_layer + 1 (mod num_metal_layers)
- Shield width = max(signal_width, min_width[shield_layer])
- Shield expansion = min_spacing[shield_layer] on each side
- Minimum shield segment length = 2 * via_pitch (contacted both ends)

## Edge Cases

| Case | Handling |
|------|----------|
| Top metal layer has no layer+1 | No shield generated, warning logged |
| DRC conflict on shield rect | Segment skipped (gap in shield allowed) |
| Signal segment too short for via pitch | Skip — can't place contacts both ends |
| Shield layer occupied by other signal | Skip via stitching for that segment |

## Dependencies

- Phase 1 (AnalogRouteDB, NetIdx) — ShieldDB uses NetIdx
- Phase 2 (SpatialDrcChecker) — used for conflict queries, falls back to InlineDrcChecker if unavailable
- Phase 3 (AnalogGroups) — shielded groups marked with `.shielded` type

## Exit Criteria

- [ ] `routeShielded()` generates shield wires on adjacent layer
- [ ] `routeDrivenGuard()` generates shield wires with signal_net = guard_net
- [ ] DRC conflicts cause shield segments to be skipped (no crashes)
- [ ] No shorts between shield and signal nets
- [ ] All shield wires have width >= min_width[shield_layer]
