# Analog Placer Implementation Plan

Complete implementation plan for all gaps identified in ARCH.md.
Priority: **accuracy first, performance second.**
Approach: **data-oriented design** — flat arrays, SoA where it matters, existence-based processing, integer IDs.

---

## Current State Summary

```
types.zig          — DeviceIdx/NetIdx/PinIdx/ConstraintIdx opaque enums (u32), ConstraintType enum {symmetry,matching,proximity,isolation}
device_arrays.zig  — DeviceArrays: parallel arrays of types/params/positions/dimensions/embeddings/predicted_cap
cost.zig           — CostFunction: 6-term (HPWL, area, symmetry, matching, RUDY, overlap), Constraint struct {kind, dev_a, dev_b, axis_x}
sa.zig             — SA engine: translate/swap/mirror_swap moves, κ·N schedule, 3-phase cooling, reheating, hierarchical macro placement
rudy.zig           — RUDY grid: rectangular uniform wire density, incremental update, overflow metric
```

**Key invariant**: `device_positions: [][2]f32` and `device_dimensions: [][2]f32` are the hot arrays. Every SA move reads/writes positions. Cost function reads positions + dimensions. Pin positions derived from device positions + offsets.

**Device count**: analog circuits typically 10–500 devices. Not millions. DOD still helps (tight inner loops per SA iteration × 10K–100K iterations), but we don't need extreme SoA splitting. The hot loop is `runOneMove` called O(κ·N·T_levels) times.

---

## Phase 0: Wire Up Dead Constraint Types (proximity + isolation)

**Priority**: P0 — smallest change, biggest structural fix. Two constraint types exist in the enum but produce zero cost.

### 0A. Extend Constraint struct

**File**: `cost.zig:17-22`

Current:
```zig
pub const Constraint = struct {
    kind: ConstraintType,
    dev_a: u32,
    dev_b: u32,
    axis_x: f32, // only meaningful for symmetry constraints
};
```

Problem: `axis_x` is overloaded (symmetry axis). Proximity needs a `max_distance` threshold. Isolation needs a `min_distance` threshold. Both are scalar f32, so repurpose the same field with a name change, OR add a union.

**Decision**: Use a flat struct with a renamed field. One `f32` parameter is sufficient for all four constraint types:
- `symmetry` → `param` = axis x-coordinate
- `matching` → `param` = unused (min_sep derived from dimensions)
- `proximity` → `param` = maximum allowed distance (penalty if exceeded)
- `isolation` → `param` = minimum required distance (penalty if violated)

```zig
pub const Constraint = struct {
    kind: ConstraintType,
    dev_a: u32,
    dev_b: u32,
    /// Meaning depends on `kind`:
    ///   symmetry  → x-coordinate of symmetry axis
    ///   matching  → unused (0.0)
    ///   proximity → maximum distance threshold
    ///   isolation → minimum distance threshold
    param: f32,
};
```

Rename `axis_x` → `param` everywhere. This is a mechanical find-replace across cost.zig, sa.zig, tests.zig. No semantic change for existing code — symmetry still reads `c.param` where it read `c.axis_x`.

### 0B. Add computeProximity function

**File**: `cost.zig`, new function after `computeMatching`

```zig
/// Σ over proximity constraints. Penalizes distance exceeding threshold.
/// Cost = max(0, dist - max_dist)²
///
/// Use case: decoupling caps near sensitive circuits, bias devices near mirrors.
pub fn computeProximity(
    positions: []const [2]f32,
    constraints: []const Constraint,
) f32 {
    var sum: f32 = 0.0;
    for (constraints) |c| {
        if (c.kind != .proximity) continue;
        const dx = positions[c.dev_a][0] - positions[c.dev_b][0];
        const dy = positions[c.dev_a][1] - positions[c.dev_b][1];
        const dist = @sqrt(dx * dx + dy * dy);
        const excess = dist - c.param; // param = max_distance
        if (excess > 0.0) sum += excess * excess;
    }
    return sum;
}
```

### 0C. Add computeIsolation function

**File**: `cost.zig`, new function after `computeProximity`

```zig
/// Σ over isolation constraints. Penalizes closeness below threshold.
/// Cost = max(0, min_dist - dist)²
///
/// Use case: analog-digital separation, substrate noise isolation.
pub fn computeIsolation(
    positions: []const [2]f32,
    device_dimensions: []const [2]f32,
    constraints: []const Constraint,
) f32 {
    var sum: f32 = 0.0;
    for (constraints) |c| {
        if (c.kind != .isolation) continue;
        const dx = positions[c.dev_a][0] - positions[c.dev_b][0];
        const dy = positions[c.dev_a][1] - positions[c.dev_b][1];
        const dist = @sqrt(dx * dx + dy * dy);
        // Subtract half-dimensions to get edge-to-edge distance
        var edge_dist = dist;
        if (device_dimensions.len > c.dev_a and device_dimensions.len > c.dev_b) {
            const half_a = @max(device_dimensions[c.dev_a][0], device_dimensions[c.dev_a][1]) / 2.0;
            const half_b = @max(device_dimensions[c.dev_b][0], device_dimensions[c.dev_b][1]) / 2.0;
            edge_dist = dist - half_a - half_b;
        }
        const violation = c.param - edge_dist; // param = min_distance
        if (violation > 0.0) sum += violation * violation;
    }
    return sum;
}
```

### 0D. Integrate into CostFunction

**File**: `cost.zig`

Add to `CostWeights`:
```zig
w_proximity: f32 = 1.0,
w_isolation: f32 = 1.0,
```

Add cached fields to `CostFunction`:
```zig
proximity_cost: f32 = 0.0,
isolation_cost: f32 = 0.0,
```

Update `computeFull` — add two calls after matching:
```zig
self.proximity_cost = computeProximity(device_positions, constraints);
self.isolation_cost = computeIsolation(device_positions, device_dimensions, constraints);
```

Update `combinedCost`:
```zig
+ w.w_proximity * self.proximity_cost
+ w.w_isolation * self.isolation_cost
```

Update `computeDeltaCost` — add recomputation of proximity and isolation (same pattern as symmetry/matching: full recompute, constraint lists are tiny).

Update `acceptDelta` signature — add `new_proximity: f32, new_isolation: f32` params. Update all call sites in sa.zig.

Update `DeltaResult` — add `new_proximity: f32, new_isolation: f32`.

### 0E. Wire weights through SaConfig

**File**: `sa.zig`

Add to `SaConfig`:
```zig
w_proximity: f32 = 1.0,
w_isolation: f32 = 1.0,
```

Update `CostWeights` construction in `runSa`:
```zig
.w_proximity = config.w_proximity,
.w_isolation = config.w_isolation,
```

### 0F. Tests

**File**: `cost.zig` module tests + `tests.zig`

```
test "computeProximity zero when within threshold"
test "computeProximity penalty when exceeding threshold"
test "computeIsolation zero when far enough"
test "computeIsolation penalty when too close"
test "CostFunction computeFull includes proximity and isolation"
```

---

## Phase 1: Add Y-Axis Symmetry

**Priority**: P0 — small change, completes the symmetry constraint system.

### 1A. Extend ConstraintType

**File**: `types.zig:98-103`

```zig
pub const ConstraintType = enum(u8) {
    symmetry_x = 0,   // renamed from 'symmetry'
    matching = 1,
    proximity = 2,
    isolation = 3,
    symmetry_y = 4,    // NEW: horizontal-axis mirror
};
```

**Decision — rename vs. add**: Renaming `symmetry` → `symmetry_x` is cleaner and self-documenting. But it breaks the C-ABI enum value. Since `SaConfig` is `extern struct`, constraint type values may be set from C callers.

**Final decision**: Keep `symmetry = 0` as-is (X-axis mirror). Add `symmetry_y = 4` for Y-axis mirror. This preserves ABI. All existing `c.kind == .symmetry` checks continue to work.

```zig
pub const ConstraintType = enum(u8) {
    symmetry = 0,
    matching = 1,
    proximity = 2,
    isolation = 3,
    symmetry_y = 4,
};
```

### 1B. Extend Constraint struct

No struct change needed. For `symmetry_y`, `param` (formerly `axis_x`) stores the Y-coordinate of the horizontal symmetry axis.

### 1C. Update computeSymmetry

**File**: `cost.zig`, modify `computeSymmetry`

```zig
pub fn computeSymmetry(
    positions: []const [2]f32,
    constraints: []const Constraint,
    norm: SymmetryNorm,
) f32 {
    var sum: f32 = 0.0;
    for (constraints) |c| {
        if (c.kind == .symmetry) {
            // X-axis mirror: devices reflected about vertical axis x = param
            const xa = positions[c.dev_a][0];
            const ya = positions[c.dev_a][1];
            const xb = positions[c.dev_b][0];
            const yb = positions[c.dev_b][1];
            const dx = xa + xb - 2.0 * c.param;
            const dy = ya - yb;
            sum += switch (norm) {
                .L1 => @abs(dx) + @abs(dy),
                .L2 => dx * dx + dy * dy,
            };
        } else if (c.kind == .symmetry_y) {
            // Y-axis mirror: devices reflected about horizontal axis y = param
            const xa = positions[c.dev_a][0];
            const ya = positions[c.dev_a][1];
            const xb = positions[c.dev_b][0];
            const yb = positions[c.dev_b][1];
            const dx = xa - xb;
            const dy = ya + yb - 2.0 * c.param;
            sum += switch (norm) {
                .L1 => @abs(dx) + @abs(dy),
                .L2 => dx * dx + dy * dy,
            };
        }
    }
    return sum;
}
```

### 1D. Update mirror_swap in sa.zig

**File**: `sa.zig`, `runSwapMove`

When detecting symmetry constraint, also check `.symmetry_y`:
```zig
if (c.kind == .symmetry or c.kind == .symmetry_y) { ... }
```

For Y-axis mirror swap, the mirror formula changes:
```zig
if (c.kind == .symmetry_y) {
    // Mirror about horizontal axis: new_y = 2·axis - old_y
    device_positions[dev_i][0] = old_pos_i[0];
    device_positions[dev_i][1] = 2.0 * sym_axis - old_pos_i[1];
    device_positions[dev_j][0] = old_pos_i[0];
    device_positions[dev_j][1] = old_pos_i[1];
}
```

Store the constraint kind alongside `sym_axis` so the swap knows which axis to mirror:
```zig
var sym_kind: ConstraintType = .symmetry;
// ... inside detection loop:
sym_kind = c.kind;
sym_axis = c.param;
```

### 1E. Tests

```
test "computeSymmetry Y-axis perfect mirror"
test "computeSymmetry Y-axis imperfect placement"
test "computeSymmetry mixed X and Y constraints"
```

---

## Phase 2: Device Orientation Tracking

**Priority**: P1 — medium effort, prevents ~5% mismatch from orientation differences.

### 2A. Add Orientation enum

**File**: `types.zig`

```zig
/// Standard 8 DEF orientations for placed instances.
/// N = north (default, no transform), S = south (180°), etc.
pub const Orientation = enum(u8) {
    N  = 0,  // no rotation
    S  = 1,  // 180° rotation
    FN = 2,  // flip-north (mirror about Y axis)
    FS = 3,  // flip-south (mirror about Y axis + 180°)
    E  = 4,  // 90° clockwise
    W  = 5,  // 90° counter-clockwise
    FE = 6,  // flip + 90° CW
    FW = 7,  // flip + 90° CCW
};
```

### 2B. Add orientation array to DeviceArrays

**File**: `device_arrays.zig`

Add field:
```zig
orientations: []Orientation,
```

In `init`:
```zig
const orients = try allocator.alloc(Orientation, n);
errdefer allocator.free(orients);
@memset(orients, .N);
```

In `deinit`:
```zig
self.allocator.free(self.orientations);
```

### 2C. Add orientation_match constraint type

**File**: `types.zig`

```zig
pub const ConstraintType = enum(u8) {
    symmetry = 0,
    matching = 1,
    proximity = 2,
    isolation = 3,
    symmetry_y = 4,
    orientation_match = 5,  // NEW
};
```

### 2D. Add computeOrientationMismatch

**File**: `cost.zig`

```zig
/// Σ over orientation_match constraints. Returns count of mismatched pairs.
/// Binary penalty: 0 if orientations match, 1.0 if they differ.
/// Multiplied by weight, this creates a hard incentive for SA to fix orientation.
pub fn computeOrientationMismatch(
    orientations: []const Orientation,
    constraints: []const Constraint,
) f32 {
    var sum: f32 = 0.0;
    for (constraints) |c| {
        if (c.kind != .orientation_match) continue;
        if (orientations[c.dev_a] != orientations[c.dev_b]) {
            sum += 1.0;
        }
    }
    return sum;
}
```

### 2E. Add orientation flip SA move

**File**: `sa.zig`

Add to `MoveType`:
```zig
orientation_flip,
```

New move function:
```zig
fn runOrientationFlipMove(...) bool {
    // Pick random device
    // Pick random new orientation from {N, S, FN, FS, E, W, FE, FW}
    // Save old orientation
    // Apply new orientation
    // Recompute cost (only orientation_mismatch term changes;
    //   but if orientation affects pin offsets, also recompute pins)
    // Metropolis accept/reject
}
```

**Critical design point**: Orientation changes can affect pin offsets. When a device is rotated, its pin positions relative to device center change. The pin offset transform for each orientation:

```
N:  (ox, oy) → ( ox,  oy)
S:  (ox, oy) → (-ox, -oy)
FN: (ox, oy) → (-ox,  oy)
FS: (ox, oy) → ( ox, -oy)
E:  (ox, oy) → ( oy, -ox)
W:  (ox, oy) → (-oy,  ox)
FE: (ox, oy) → ( oy,  ox)
FW: (ox, oy) → (-oy, -ox)
```

This means `PinInfo.offset_x/y` are the **base** offsets (orientation N). The actual offset must be transformed by device orientation before computing pin positions.

### 2F. Update pin position computation

**File**: `sa.zig`, modify `updatePinPositionsForDevice` and `recomputeAllPinPositions`

```zig
fn transformPinOffset(ox: f32, oy: f32, orient: Orientation) [2]f32 {
    return switch (orient) {
        .N  => .{  ox,  oy },
        .S  => .{ -ox, -oy },
        .FN => .{ -ox,  oy },
        .FS => .{  ox, -oy },
        .E  => .{  oy, -ox },
        .W  => .{ -oy,  ox },
        .FE => .{  oy,  ox },
        .FW => .{ -oy, -ox },
    };
}
```

`recomputeAllPinPositions` gains an `orientations: []const Orientation` parameter. Pin position = device_position + transformPinOffset(offset, orientation).

This propagates to `runSa` (must pass orientations), `runTranslateMove`, `runSwapMove`.

### 2G. Add w_orientation to CostWeights and SaConfig

Follow same pattern as Phase 0.

### 2H. Integrate into CostFunction

Add `orientation_cost: f32 = 0.0` cached field.
Add to `computeFull`, `computeDeltaCost`, `combinedCost`, `acceptDelta`, `DeltaResult`.

`computeFull` and `computeDeltaCost` now require `orientations` parameter.

### 2I. Move probability

Add `p_orientation_flip: f32 = 0.05` to `SaConfig`. In `runOneMove`, roll:
```
if roll < p_orientation_flip → orientation_flip
elif roll < p_orientation_flip + p_swap → swap
else → translate
```

### 2J. Tests

```
test "transformPinOffset all 8 orientations"
test "computeOrientationMismatch matched pair"
test "computeOrientationMismatch different orientations"
test "SA orientation flip reduces mismatch"
```

---

## Phase 3: Common-Centroid Constraint

**Priority**: P1 — mandatory for diff pairs, bandgaps, DACs.

### 3A. Add constraint type

**File**: `types.zig`

```zig
common_centroid = 6,
```

### 3B. Add device group representation

Common-centroid constrains **groups** of unit cells, not pairs. A common-centroid constraint says: "the centroid of group A's unit cells must coincide with the centroid of group B's unit cells."

**Representation decision**: The `Constraint` struct currently pairs two individual devices. For common-centroid, we need to reference groups. Two approaches:

1. **Sidecar array** (DOD extra[] pattern): Constraint stores indices into a sidecar `group_members: []u32` array.
2. **Multiple pairwise constraints**: Decompose into O(n²) pair constraints.

**Decision**: Sidecar array. Reason: common-centroid is fundamentally a group property. Decomposing into pairs loses the centroid-coincidence invariant (pairwise doesn't guarantee group centroid match).

**File**: `cost.zig`

```zig
/// Common-centroid group definition. Stored in a sidecar array.
/// A constraint with kind == .common_centroid has param encoding the
/// index into the CentroidGroup sidecar.
pub const CentroidGroup = struct {
    /// Device indices belonging to group A.
    group_a: []const u32,
    /// Device indices belonging to group B.
    group_b: []const u32,
};
```

Add to `CostFunction`:
```zig
centroid_groups: []const CentroidGroup = &.{},
```

Set in `computeFull`, pass through from caller.

### 3C. Add computeCommonCentroid

**File**: `cost.zig`

```zig
/// Common-centroid cost: sum of squared centroid distances.
///
/// For each group pair (A, B):
///   centroid_A = (1/|A|) * Σ_{i∈A} pos[i]
///   centroid_B = (1/|B|) * Σ_{j∈B} pos[j]
///   cost += (centroid_Ax - centroid_Bx)² + (centroid_Ay - centroid_By)²
pub fn computeCommonCentroid(
    positions: []const [2]f32,
    groups: []const CentroidGroup,
) f32 {
    var sum: f32 = 0.0;
    for (groups) |g| {
        if (g.group_a.len == 0 or g.group_b.len == 0) continue;

        var ax: f32 = 0.0;
        var ay: f32 = 0.0;
        for (g.group_a) |dev| {
            ax += positions[dev][0];
            ay += positions[dev][1];
        }
        ax /= @floatFromInt(g.group_a.len);
        ay /= @floatFromInt(g.group_a.len);

        var bx: f32 = 0.0;
        var by: f32 = 0.0;
        for (g.group_b) |dev| {
            bx += positions[dev][0];
            by += positions[dev][1];
        }
        bx /= @floatFromInt(g.group_b.len);
        by /= @floatFromInt(g.group_b.len);

        const dx = ax - bx;
        const dy = ay - by;
        sum += dx * dx + dy * dy;
    }
    return sum;
}
```

### 3D. Integrate

Same pattern: `w_common_centroid: f32 = 2.0` in CostWeights/SaConfig.
Add to CostFunction cached fields, combinedCost, computeFull, computeDeltaCost, acceptDelta, DeltaResult.

### 3E. Group-aware SA move (optional enhancement)

A translate move on one device in a CC group is fine — the cost function will drive centroid coincidence. But a **group translate** move (shift all devices in one group together) can help convergence:

Add `group_translate` to MoveType. In `runOneMove`, if CC groups exist with probability `p_group_translate`:
- Pick random CC group
- Pick group A or B
- Translate all devices in that group by same (dx, dy)
- Accept/reject based on total cost delta

This is optional — CC cost term alone may be sufficient for SA convergence at analog scale.

### 3F. Tests

```
test "computeCommonCentroid zero when centroids coincide"
test "computeCommonCentroid nonzero when centroids differ"
test "computeCommonCentroid ABBA pattern achieves zero cost"
```

---

## Phase 4: LDE-Aware Cost Term (SA/SB Equalization)

**Priority**: P1 — dominant mismatch source at ≤65nm.

### 4A. SA/SB computation model

SA (Source-to-STI-edge distance) and SB (Drain-to-STI-edge distance) depend on the diffusion geometry surrounding each MOSFET. In a placer context, we approximate:

- Each MOSFET has a diffusion region extending from gate edge to the nearest STI boundary.
- The nearest STI boundary is approximated as the nearest edge of any adjacent device's active area, or the array boundary.

**Simplification**: For matched pairs, what matters is **ΔSA** and **ΔSB**, not absolute values. If two matched MOSFETs see the same surrounding geometry, their LDE contributions cancel. The cost term penalizes asymmetry in local geometry.

### 4B. LDE context computation

**File**: `cost.zig`, new function

```zig
/// Approximate SA/SB for a MOSFET device given surrounding device positions.
/// SA = distance from device's left diffusion edge to nearest STI (left neighbor or array edge).
/// SB = distance from device's right diffusion edge to nearest STI (right neighbor or array edge).
///
/// For a device at (x, y) with width w:
///   left_diff_edge  = x - w/2
///   right_diff_edge = x + w/2
///   SA = min(left_diff_edge - 0, min over left-neighbors of (left_diff_edge - neighbor_right_edge))
///   SB = min(array_width - right_diff_edge, min over right-neighbors of (neighbor_left_edge - right_diff_edge))
pub fn computeDeviceSaSb(
    dev: u32,
    positions: []const [2]f32,
    dimensions: []const [2]f32,
    array_width: f32,
) [2]f32 {
    const x = positions[dev][0];
    const w = if (dimensions.len > dev and dimensions[dev][0] > 0.0)
        dimensions[dev][0]
    else
        2.0; // default
    const left_edge = x - w / 2.0;
    const right_edge = x + w / 2.0;

    var sa: f32 = left_edge; // distance to left array boundary
    var sb: f32 = array_width - right_edge; // distance to right array boundary

    for (positions, 0..) |pos, i| {
        if (i == dev) continue;
        const ow = if (dimensions.len > i and dimensions[i][0] > 0.0)
            dimensions[i][0]
        else
            2.0;
        const neighbor_right = pos[0] + ow / 2.0;
        const neighbor_left = pos[0] - ow / 2.0;

        // Check if neighbor is to the left
        if (neighbor_right < left_edge) {
            sa = @min(sa, left_edge - neighbor_right);
        }
        // Check if neighbor is to the right
        if (neighbor_left > right_edge) {
            sb = @min(sb, neighbor_left - right_edge);
        }
    }

    return .{ @max(sa, 0.0), @max(sb, 0.0) };
}
```

### 4C. LDE cost function

```zig
/// LDE mismatch cost: Σ over matching constraints of (ΔSA² + ΔSB²).
/// Only applies to MOSFET devices (checked via device_types if provided).
pub fn computeLde(
    positions: []const [2]f32,
    dimensions: []const [2]f32,
    constraints: []const Constraint,
    array_width: f32,
) f32 {
    var sum: f32 = 0.0;
    for (constraints) |c| {
        if (c.kind != .matching) continue;
        const sa_sb_a = computeDeviceSaSb(c.dev_a, positions, dimensions, array_width);
        const sa_sb_b = computeDeviceSaSb(c.dev_b, positions, dimensions, array_width);
        const d_sa = sa_sb_a[0] - sa_sb_b[0];
        const d_sb = sa_sb_a[1] - sa_sb_b[1];
        sum += d_sa * d_sa + d_sb * d_sb;
    }
    return sum;
}
```

**Note**: LDE cost piggybacks on `matching` constraints. Every matched pair automatically gets LDE awareness. No new constraint type needed.

### 4D. Integrate

`w_lde: f32 = 1.0` in CostWeights/SaConfig.
Cached `lde_cost: f32 = 0.0` in CostFunction.
`computeFull` passes `layout_width` for `array_width`.
Add to combinedCost, computeDeltaCost, acceptDelta, DeltaResult.

### 4E. Performance note

`computeDeviceSaSb` is O(N) per device. `computeLde` is O(M·N) where M = matched pairs, N = devices. For analog scale (M < 50, N < 500), this is < 25K operations — negligible vs. HPWL.

### 4F. Tests

```
test "computeDeviceSaSb symmetric neighbors"
test "computeDeviceSaSb asymmetric neighbors"
test "computeLde zero when matched devices have identical geometry"
test "computeLde nonzero when asymmetric placement"
```

---

## Phase 5: Thermal Symmetry

**Priority**: P2 — small effort, prevents mV-level thermal mismatch.

### 5A. Heat source model

Heat sources are provided as input — power-dissipating devices with known positions and power.

**File**: `cost.zig`

```zig
/// A heat source for thermal symmetry computation.
pub const HeatSource = struct {
    x: f32,
    y: f32,
    power: f32, // watts (or relative units)
};
```

### 5B. Thermal field approximation

```zig
/// Approximate thermal field at a point due to all heat sources.
/// Uses inverse-square-distance model: T(pos) ≈ Σ_k P_k / max(|pos - H_k|², ε)
/// ε prevents singularity when device is at heat source.
fn thermalField(x: f32, y: f32, heat_sources: []const HeatSource) f32 {
    const epsilon: f32 = 1.0; // µm² — prevents div-by-zero
    var t: f32 = 0.0;
    for (heat_sources) |h| {
        const dx = x - h.x;
        const dy = y - h.y;
        t += h.power / @max(dx * dx + dy * dy, epsilon);
    }
    return t;
}
```

### 5C. Thermal symmetry cost

```zig
/// Thermal mismatch: Σ over matching constraints of |T(pos_a) - T(pos_b)|².
pub fn computeThermalMismatch(
    positions: []const [2]f32,
    constraints: []const Constraint,
    heat_sources: []const HeatSource,
) f32 {
    if (heat_sources.len == 0) return 0.0;
    var sum: f32 = 0.0;
    for (constraints) |c| {
        if (c.kind != .matching) continue;
        const ta = thermalField(positions[c.dev_a][0], positions[c.dev_a][1], heat_sources);
        const tb = thermalField(positions[c.dev_b][0], positions[c.dev_b][1], heat_sources);
        const dt = ta - tb;
        sum += dt * dt;
    }
    return sum;
}
```

**Note**: Like LDE, thermal piggybacks on `matching` constraints. No new constraint type.

### 5D. Integrate

`w_thermal: f32 = 0.5` in CostWeights/SaConfig.
CostFunction stores `heat_sources: []const HeatSource = &.{}`, set in `computeFull`.
`thermal_cost: f32 = 0.0` cached.
Pass through `heat_sources` from `runSa` (new parameter, default `&.{}`).

### 5E. Tests

```
test "thermalField inverse square law"
test "computeThermalMismatch zero when equidistant from heat source"
test "computeThermalMismatch nonzero when asymmetric"
```

---

## Phase 6: Dummy Device Modeling

**Priority**: P2 — edge-effect compensation.

### 6A. Device flag

**File**: `device_arrays.zig`

Add `is_dummy: []bool` to DeviceArrays. Default: `false`. Dummies are excluded from HPWL, area, and matching cost but contribute to overlap and LDE geometry.

### 6B. Edge penalty cost

```zig
/// Edge penalty: for each matched device at the boundary of a device array,
/// add a penalty proportional to the number of exposed edges (edges not
/// bordered by another device of the same type and orientation).
///
/// An exposed edge causes STI stress gradient, lithography bias, and
/// implant shadowing — all of which shift Vth by 10+ mV.
pub fn computeEdgePenalty(
    positions: []const [2]f32,
    dimensions: []const [2]f32,
    constraints: []const Constraint,
    is_dummy: []const bool,
    layout_width: f32,
    layout_height: f32,
) f32 {
    var sum: f32 = 0.0;
    for (constraints) |c| {
        if (c.kind != .matching) continue;
        // Count exposed edges for dev_a and dev_b
        const ea = countExposedEdges(c.dev_a, positions, dimensions, is_dummy, layout_width, layout_height);
        const eb = countExposedEdges(c.dev_b, positions, dimensions, is_dummy, layout_width, layout_height);
        // Penalize asymmetry in edge exposure
        const delta: f32 = @floatFromInt(@as(i32, @intCast(ea)) - @as(i32, @intCast(eb)));
        sum += delta * delta;
    }
    return sum;
}
```

`countExposedEdges` checks for each of 4 sides (left, right, top, bottom) whether there is an adjacent device (non-dummy) within a threshold distance. Returns 0–4.

### 6C. Dummy insertion pass (post-SA)

After SA converges, a post-processing pass identifies array-boundary devices and inserts dummies:

```zig
/// Insert dummy devices at exposed edges of matched device arrays.
/// Rules: same size, same orientation, same spacing, gate/source/drain/body tied.
/// Returns number of dummies inserted.
pub fn insertDummies(
    allocator: std.mem.Allocator,
    device_positions: *[][2]f32,
    device_dimensions: *[][2]f32,
    orientations: *[]Orientation,
    is_dummy: *[]bool,
    constraints: []const Constraint,
) !u32 { ... }
```

This is a **post-placement** step. Dummies don't participate in SA — they're deterministically placed after SA based on final positions. This avoids expanding the SA search space.

### 6D. Integrate

`w_edge_penalty: f32 = 0.5` in CostWeights/SaConfig.
Add to CostFunction.

### 6E. Tests

```
test "countExposedEdges interior device has 0"
test "countExposedEdges corner device has 2"
test "computeEdgePenalty symmetric placement"
test "insertDummies adds dummies at array edges"
```

---

## Phase 7: Interdigitation Constraint

**Priority**: P2 — 1D gradient cancellation for current mirrors.

### 7A. Constraint type

```zig
interdigitation = 7,
```

### 7B. Representation

Interdigitation constrains an ordered sequence of unit cells along one axis. Like common-centroid, this is a group constraint. Reuse the `CentroidGroup` sidecar (rename to `DeviceGroup`):

```zig
pub const DeviceGroup = struct {
    group_a: []const u32,
    group_b: []const u32,
};
```

### 7C. Interdigitation cost

```zig
/// Interdigitation cost: measures how well unit cells alternate along X axis.
///
/// Sort all devices in groups A and B by X position. Ideal pattern: ABABAB...
/// Cost = number of adjacent same-group violations + centroid imbalance.
///
/// For perfect interdigitation:
///   Σ_{k∈A} x_k = Σ_{k∈B} x_k  (1D gradient cancellation)
pub fn computeInterdigitation(
    positions: []const [2]f32,
    groups: []const DeviceGroup,
    scratch: []u32, // scratch buffer, len >= max group size
) f32 {
    var sum: f32 = 0.0;
    for (groups) |g| {
        const total = g.group_a.len + g.group_b.len;
        if (total < 2) continue;

        // 1. Centroid imbalance (primary)
        var sum_a: f32 = 0.0;
        for (g.group_a) |dev| sum_a += positions[dev][0];
        var sum_b: f32 = 0.0;
        for (g.group_b) |dev| sum_b += positions[dev][0];
        if (g.group_a.len > 0 and g.group_b.len > 0) {
            const centroid_a = sum_a / @floatFromInt(g.group_a.len);
            const centroid_b = sum_b / @floatFromInt(g.group_b.len);
            const dc = centroid_a - centroid_b;
            sum += dc * dc;
        }

        // 2. Adjacency violations (secondary — drives ABABAB pattern)
        // Merge all devices, sort by X, count same-group adjacencies
        // Each same-group adjacency = one violation
        // (implementation uses scratch buffer to sort indices by position)
    }
    return sum;
}
```

### 7D. Integrate

`w_interdigitation: f32 = 1.5`.
Same integration pattern.

### 7E. Tests

```
test "computeInterdigitation perfect ABAB has zero centroid imbalance"
test "computeInterdigitation AABB has nonzero cost"
```

---

## Phase 8: Parasitic Routing Balance

**Priority**: P3 — catches wiring-destroys-matching failure.

### 8A. Routing length estimation

For each matched device pair on a shared net, estimate routing length as Manhattan distance from device to net centroid:

```zig
/// Estimated routing length from device to net centroid.
fn estimatedRouteLength(
    dev: u32,
    net: u32,
    device_positions: []const [2]f32,
    pin_positions: []const [2]f32,
    adj: NetAdjacency,
) f32 {
    // Compute net centroid
    const start = adj.net_pin_starts[net];
    const end = adj.net_pin_starts[net + 1];
    if (end <= start) return 0.0;

    var cx: f32 = 0.0;
    var cy: f32 = 0.0;
    for (start..end) |k| {
        const pid = adj.pin_list[k].toInt();
        cx += pin_positions[pid][0];
        cy += pin_positions[pid][1];
    }
    const n: f32 = @floatFromInt(end - start);
    cx /= n;
    cy /= n;

    // Manhattan distance from device position to net centroid
    return @abs(device_positions[dev][0] - cx) + @abs(device_positions[dev][1] - cy);
}
```

### 8B. Parasitic balance cost

```zig
/// Parasitic routing imbalance: for each matched pair sharing a net,
/// penalize difference in estimated routing length.
///
/// Cost = Σ_{matched_pairs} Σ_{shared_nets} (L_route_a - L_route_b)²
pub fn computeParasiticBalance(
    device_positions: []const [2]f32,
    pin_positions: []const [2]f32,
    adj: NetAdjacency,
    constraints: []const Constraint,
    device_nets: []const []const u32,
) f32 {
    var sum: f32 = 0.0;
    for (constraints) |c| {
        if (c.kind != .matching) continue;
        // Find shared nets between dev_a and dev_b
        for (device_nets[c.dev_a]) |net_a| {
            for (device_nets[c.dev_b]) |net_b| {
                if (net_a != net_b) continue;
                const la = estimatedRouteLength(c.dev_a, net_a, device_positions, pin_positions, adj);
                const lb = estimatedRouteLength(c.dev_b, net_a, device_positions, pin_positions, adj);
                const dl = la - lb;
                sum += dl * dl;
            }
        }
    }
    return sum;
}
```

### 8C. Integrate

`w_parasitic: f32 = 0.3`.
This term requires `device_nets` in CostFunction, which is currently only built inside `runSa`. Pass it through or store reference.

### 8D. Tests

```
test "computeParasiticBalance zero when symmetric routing"
test "computeParasiticBalance nonzero when asymmetric"
```

---

## Phase 9: Guard Ring / Well Geometry Awareness

**Priority**: P3 — large effort, WPE compensation.

### 9A. Well boundary model

```zig
/// A well region in the layout (N-well or P-well).
pub const WellRegion = struct {
    x_min: f32,
    y_min: f32,
    x_max: f32,
    y_max: f32,
    well_type: enum(u8) { nwell, pwell },
};
```

### 9B. Device-to-well-edge distance

```zig
/// Minimum distance from device center to nearest well edge.
/// WPE causes ΔVth = f(distance_to_well_edge) that decays over ~1µm.
fn deviceToWellEdge(
    dev: u32,
    positions: []const [2]f32,
    wells: []const WellRegion,
) f32 {
    var min_dist: f32 = std.math.inf(f32);
    const x = positions[dev][0];
    const y = positions[dev][1];
    for (wells) |w| {
        // Distance to each of 4 edges
        min_dist = @min(min_dist, @abs(x - w.x_min));
        min_dist = @min(min_dist, @abs(x - w.x_max));
        min_dist = @min(min_dist, @abs(y - w.y_min));
        min_dist = @min(min_dist, @abs(y - w.y_max));
    }
    return min_dist;
}
```

### 9C. WPE cost

```zig
/// WPE mismatch: for matched pairs, penalize difference in well-edge distance.
/// Cost = Σ_matched (dist_a - dist_b)²
pub fn computeWpeMismatch(
    positions: []const [2]f32,
    constraints: []const Constraint,
    wells: []const WellRegion,
) f32 {
    if (wells.len == 0) return 0.0;
    var sum: f32 = 0.0;
    for (constraints) |c| {
        if (c.kind != .matching) continue;
        const da = deviceToWellEdge(c.dev_a, positions, wells);
        const db = deviceToWellEdge(c.dev_b, positions, wells);
        const dd = da - db;
        sum += dd * dd;
    }
    return sum;
}
```

### 9D. Guard ring validation (post-SA)

Guard ring completeness check is a post-placement DRC-like step, not an SA cost term:

```zig
/// Verify guard ring enclosure for sensitive device groups.
/// Returns list of devices with incomplete guard ring coverage.
pub fn checkGuardRings(
    positions: []const [2]f32,
    dimensions: []const [2]f32,
    guard_rings: []const GuardRing,
) []u32 { ... }
```

### 9E. Integrate

`w_wpe: f32 = 0.5`.
Wells passed as input, similar to heat_sources.

---

## Implementation Order (Dependency Graph)

```
Phase 0 ─┬─ Phase 1 ─── Phase 3 (CC needs both axes)
          │              Phase 7 (interdigitation uses DeviceGroup)
          │
          ├─ Phase 4 (LDE piggybacks on matching)
          │
          ├─ Phase 5 (thermal piggybacks on matching)
          │
          └─ Phase 8 (parasitic piggybacks on matching)

Phase 2 ─── Phase 6 (dummies need orientation tracking)

Phase 9 (standalone, needs well geometry input)
```

**Recommended execution order**:

1. **Phase 0** — proximity + isolation (unblocks everything, tiny diff)
2. **Phase 1** — Y-axis symmetry (tiny diff, completes symmetry)
3. **Phase 2** — orientation tracking (medium, foundational for Phase 6)
4. **Phase 4** — LDE (medium, high-value at ≤65nm)
5. **Phase 3** — common-centroid (medium, needs DeviceGroup sidecar)
6. **Phase 5** — thermal (small, easy win)
7. **Phase 7** — interdigitation (medium, shares DeviceGroup with Phase 3)
8. **Phase 6** — dummy devices (medium, needs Phase 2)
9. **Phase 8** — parasitic balance (medium, needs device_nets exposed)
10. **Phase 9** — guard ring/WPE (large, needs well geometry input)

---

## Shared Infrastructure Changes

### A. Rename `axis_x` → `param` in Constraint

Mechanical rename across cost.zig, sa.zig, tests.zig. All existing `.axis_x` references become `.param`. No semantic change.

### B. Expand CostWeights

Final CostWeights struct after all phases:

```zig
pub const CostWeights = struct {
    // Existing
    w_hpwl: f32 = 1.0,
    w_area: f32 = 0.5,
    w_symmetry: f32 = 2.0,
    w_matching: f32 = 1.5,
    w_rudy: f32 = 0.3,
    w_overlap: f32 = 100.0,
    symmetry_norm: SymmetryNorm = .L2,
    // Phase 0
    w_proximity: f32 = 1.0,
    w_isolation: f32 = 1.0,
    // Phase 2
    w_orientation: f32 = 5.0,
    // Phase 3
    w_common_centroid: f32 = 2.0,
    // Phase 4
    w_lde: f32 = 1.0,
    // Phase 5
    w_thermal: f32 = 0.5,
    // Phase 6
    w_edge_penalty: f32 = 0.5,
    // Phase 7
    w_interdigitation: f32 = 1.5,
    // Phase 8
    w_parasitic: f32 = 0.3,
    // Phase 9
    w_wpe: f32 = 0.5,
};
```

### C. Expand DeltaResult

Add one field per new cost term. All follow same pattern.

### D. Expand acceptDelta

Two options:
1. Add parameters one at a time (many args).
2. Pass the entire DeltaResult struct.

**Decision**: Pass `DeltaResult` by value. Cleaner, extensible, no arg-count explosion.

```zig
pub fn acceptDelta(self: *CostFunction, result: DeltaResult) void {
    self.hpwl_sum = result.new_hpwl_sum;
    self.area_cost = result.new_area;
    self.symmetry_cost = result.new_sym;
    self.matching_cost = result.new_match;
    self.rudy_overflow = result.new_rudy;
    self.overlap_cost = result.new_overlap;
    self.proximity_cost = result.new_proximity;
    self.isolation_cost = result.new_isolation;
    // ... etc for all terms
    self.total = result.new_total;
}
```

Do this refactor in Phase 0 before adding more terms. Prevents future arg-count pain.

### E. Expand SaConfig

`SaConfig` is `extern struct` for C-ABI. New fields **must go at the end** to preserve layout. Each new weight field is f32, appended after existing fields.

### F. Expand runSa signature

New optional inputs:
- `orientations: ?[]Orientation` — Phase 2+
- `heat_sources: []const HeatSource` — Phase 5+
- `centroid_groups: []const CentroidGroup` — Phase 3+
- `interdig_groups: []const DeviceGroup` — Phase 7+
- `wells: []const WellRegion` — Phase 9+
- `is_dummy: []const bool` — Phase 6+

**Decision**: Bundle into a `PlacerContext` struct to avoid arg explosion:

```zig
pub const PlacerContext = struct {
    orientations: ?[]Orientation = null,
    heat_sources: []const HeatSource = &.{},
    centroid_groups: []const CentroidGroup = &.{},
    interdig_groups: []const DeviceGroup = &.{},
    wells: []const WellRegion = &.{},
    is_dummy: []const bool = &.{},
    is_power: []const bool = &.{},
};
```

`runSa` gains a single `ctx: PlacerContext` parameter with all-default fields. Existing callers pass `PlacerContext{}` and nothing changes.

---

## DOD Analysis: What NOT to Change

The current data layout is already DOD-aligned for the hot path:

- `device_positions: [][2]f32` — contiguous, 8 bytes per device, hot
- `device_dimensions: [][2]f32` — contiguous, 8 bytes per device, warm
- `pin_positions: [][2]f32` — contiguous, 8 bytes per pin, hot
- `constraints: []const Constraint` — contiguous, 16 bytes per constraint, small count
- Net adjacency is CSR (flat arrays) — already optimal

**Do NOT convert to MultiArrayList**: Device count is 10–500. The working set fits in L1 as-is. SoA overhead (pointer arithmetic per column access) is not justified. The existing parallel-array style in `DeviceArrays` is already SoA-like (separate arrays for types, params, positions, dimensions).

**Do NOT add indirection**: New arrays (orientations, is_dummy) go as flat parallel arrays in DeviceArrays, indexed by the same device integer. This is the DOD "same integer index into multiple tables" pattern.

**DO use existence-based processing**: `is_dummy` could be a `DynamicBitSet` instead of `[]bool`, saving 7/8 of cache pressure. At 500 devices, `[]bool` = 500 bytes, `DynamicBitSet` = 64 bytes. Both fit in L1, so the difference is negligible. Use `[]bool` for simplicity.

---

## Testing Strategy

Each phase has unit tests for:
1. **Zero cost at perfect placement** — verify the math produces exactly 0.0
2. **Known nonzero cost** — hand-computed expected value, assert with tolerance
3. **Integration with CostFunction** — verify new term appears in total
4. **SA convergence** — verify SA reduces the new cost term over iterations

Tests go in both `cost.zig` (pure function tests) and `tests.zig` (integration tests with SA).

---

## Mismatch Budget Coverage After All Phases

| Mismatch Component | Coverage After Plan |
|---|---|
| σ²_random | Indirect (sizing is pre-placement). Orientation matching (Phase 2) removes ~5% error |
| σ²_gradient | Full: X+Y symmetry (Phase 0-1), common-centroid (Phase 3), interdigitation (Phase 7) |
| σ²_LDE | Full: SA/SB equalization (Phase 4), dummy devices (Phase 6), WPE (Phase 9) |
| σ²_parasitic | Partial→Good: RUDY congestion + routing balance estimation (Phase 8) |
| σ²_thermal | Full: thermal symmetry cost (Phase 5) |
| σ²_electrical | Partial: isolation constraint (Phase 0), guard ring check (Phase 9) |
