# Phase 8: LDE Router Specification

## Overview

The LDE Router (Layout Dependent Effects) handles SA/SB (Source-end to Active-edge / Body-end to Active-edge) spacing constraints and generates keepout zones around analog devices. LDE effects cause MOSFET characteristics to vary based on proximity to other devices or wells. Matched devices must maintain symmetric SA/SB to avoid mismatch.

## LDEConstraintDB SoA Table

Structure-of-Arrays database for LDE constraints, one entry per device.

| Field | Type | Description |
|-------|------|-------------|
| `device` | `DeviceIdx` | Device this constraint applies to |
| `min_sa` | `f32` | Minimum SA (Source to Active edge spacing) in micrometers |
| `max_sa` | `f32` | Maximum SA (clamp) |
| `min_sb` | `f32` | Minimum SB (Body to Active edge spacing) in micrometers |
| `max_sb` | `f32` | Maximum SB (clamp) |
| `sc_target` | `f32` | SCA (Active to Well edge) target for WPE compensation |

## LDEConstraintDB API

```zig
pub const LDEConstraintDB = struct {
    allocator: std.mem.Allocator,
    device: std.ArrayListUnmanaged(DeviceIdx),
    min_sa: std.ArrayListUnmanaged(f32),
    max_sa: std.ArrayListUnmanaged(f32),
    min_sb: std.ArrayListUnmanaged(f32),
    max_sb: std.ArrayListUnmanaged(f32),
    sc_target: std.ArrayListUnmanaged(f32),

    pub fn init(allocator: std.mem.Allocator, capacity: u32) !LDEConstraintDB
    pub fn deinit(self: *LDEConstraintDB) void
    pub fn addConstraint(self: *LDEConstraintDB, constraint: LDEConstraint) !void
    pub fn len(self: *const LDEConstraintDB) u32
    pub fn generateKeepouts(self: *const LDEConstraintDB, device_bboxes: []const Rect, allocator: std.mem.Allocator) ![]Rect
    pub fn getConstraint(self: *const LDEConstraintDB, idx: u32) ?LDEConstraint
};

pub const LDEConstraint = struct {
    device: DeviceIdx,
    min_sa: f32,
    max_sa: f32,
    min_sb: f32,
    max_sb: f32,
    sc_target: f32,
};
```

## Algorithm: generateKeepouts(device_bboxes)

Produces axis-aligned rectangular keepout zones around each device, expanded by min_sa/min_sb:

1. For each device i with constraint i:
   - Compute SA keepout: expand device bbox by `min_sa` on source-facing side
   - Compute SB keepout: expand device bbox by `min_sb` on body-facing side
   - Union of SA and SB expansions = combined keepout rect
2. Return array of keepout rectangles

Device bbox orientation (which side is "source" vs "body") is determined by device type:
- NMOS: left = source, right = body
- PMOS: right = source, left = body

## LDE Cost for A* Expansion

```zig
pub fn computeLDECost(
    sa_a: f32,
    sb_a: f32,
    sa_b: f32,
    sb_b: f32,
) f32 {
    const sa_diff = @abs(sa_a - sa_b);
    const sb_diff = @abs(sb_a - sb_b);
    return sa_diff + sb_diff;
}
```

Penalizes SA/SB asymmetry between matched devices. Perfectly symmetric placement = zero cost.

For more precise matching, a scaled version:

```zig
pub fn computeLDECostScaled(
    sa_a: f32, sb_a: f32,
    sa_b: f32, sb_b: f32,
    tolerance: f32,
) f32 {
    const sa_diff = @abs(sa_a - sa_b);
    const sb_diff = @abs(sb_a - sb_b);
    const sa_score = if (sa_diff > tolerance) sa_diff - tolerance else 0;
    const sb_score = if (sb_diff > tolerance) sb_diff - tolerance else 0;
    return sa_score + sb_score;
}
```

## Rect Helper

```zig
pub const Rect = struct {
    x1: f32,
    y1: f32,
    x2: f32,
    y2: f32,

    pub fn width(self: Rect) f32 { return self.x2 - self.x1; }
    pub fn height(self: Rect) f32 { return self.y2 - self.y1; }
    pub fn expand(self: Rect, amount: f32) Rect {
        return .{
            .x1 = self.x1 - amount,
            .y1 = self.y1 - amount,
            .x2 = self.x2 + amount,
            .y2 = self.y2 + amount,
        };
    }
};
```

## Edge Cases

| Case | Handling |
|------|----------|
| No LDE constraints | Return empty keepout list |
| SA/SB both 0 | Keepout = device bbox (no expansion) |
| Device not in constraint DB | No keepout generated for that device |
| max_sa/max_sb exceeded | Clamp routing to stay within max bounds |

## WPE Exclusion Zones

Well Proximity Effect (WPE) from the SC_target parameter:
- SCA = distance from Active to Well edge
- SC_target = desired SCA for WPE compensation
- Keepout zone ensures routing does not alter SCA from target

Generated as additional rect expansions on the well-facing side.

## Dependencies

- Phase 1 (`DeviceIdx`) — device identification
- Uses `Rect` defined locally (duplicated from IMPL_PLAN.md for self-contained module)
- Standalone module, no router dependencies

## Exit Criteria

- [ ] `generateKeepouts()` produces correct SA/SB-expanded rectangles
- [ ] `computeLDECost()` returns 0 for symmetric SA/SB
- [ ] `computeLDECost()` > 0 for asymmetric SA/SB
- [ ] `computeLDECostScaled()` respects tolerance parameter
- [ ] All tests pass: `zig build test 2>&1 | head -50`
