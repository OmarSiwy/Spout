# Phase 6: Guard Ring Inserter Specification

## Overview

The Guard Ring Inserter places P+/N+ pickup rings and deep N-well rings around analog blocks to provide isolation from substrate noise and latchup.

## GuardRingDB SoA Table

| Field | Type | Description |
|-------|------|-------------|
| `bbox_x1` | `f32` | Ring outer bounding box min-X |
| `bbox_y1` | `f32` | Ring outer bounding box min-Y |
| `bbox_x2` | `f32` | Ring outer bounding box max-X |
| `bbox_y2` | `f32` | Ring outer bounding box max-Y |
| `inner_x1` | `f32` | Ring inner rect min-X (donut hole) |
| `inner_y1` | `f32` | Ring inner rect min-Y |
| `inner_x2` | `f32` | Ring inner rect max-X |
| `inner_y2` | `f32` | Ring inner rect max-Y |
| `ring_type` | `GuardRingType` | P+, N+, deep N-well, or composite |
| `net` | `NetIdx` | Net connected to ring (VSS or VDD) |
| `contact_pitch` | `f32` | Spacing between contacts |
| `has_stitch_in` | `bool` | True if ring overlaps existing metal |

## GuardRingType Enum

```zig
pub const GuardRingType = enum(u8) {
    p_plus = 0,    // P+ diffusion ring (for N-substrate isolation)
    n_plus = 1,    // N+ diffusion ring (for P-well isolation)
    deep_nwell = 2, // Deep N-well ring (for triple-well isolation)
    composite = 3,  // P+ + deep N-well combined
};
```

## GuardRingInserter API

```zig
pub const GuardRingInserter = struct {
    db: GuardRingDB,
    allocator: std.mem.Allocator,
    pdk: *const PdkConfig,
    drc: ?*InlineDrcChecker,

    pub fn init(allocator: std.mem.Allocator, pdk: *const PdkConfig, drc: ?*InlineDrcChecker) !GuardRingInserter
    pub fn deinit(self: *GuardRingInserter) void
    pub fn insert(self: *GuardRingInserter, region: Rect, ring_type: GuardRingType, net: NetIdx) !GuardRingIdx
    pub fn insertWithStitchIn(self: *GuardRingInserter, region: Rect, ring_type: GuardRingType, net: NetIdx, existing_metal: []const Rect) !GuardRingIdx
    pub fn clipToDieEdge(self: *GuardRingInserter, die_bbox: Rect) void
    pub fn mergeDeepNWell(self: *GuardRingInserter, other: GuardRingIdx) void
};
```

## Geometry: Donut Shape

The guard ring is a "donut" = outer_rect - inner_rect:

```
outer:  (bbox_x1, bbox_y1) ---- (bbox_x2, bbox_y2)
inner:  (inner_x1, inner_y1) --/  (inner_x2, inner_y2)
                         \/
  Ring metal fills the L-shaped area between them
```

Four sides of the ring are generated as separate rectangular segments:
- Top: (inner_x1, inner_y2) to (inner_x2, bbox_y2)
- Bottom: (inner_x1, bbox_y1) to (inner_x2, inner_y1)
- Left: (bbox_x1, inner_y1) to (inner_x1, inner_y2)
- Right: (inner_x2, inner_y1) to (bbox_x2, inner_y2)

## Contact Placement

Contacts are placed along each ring segment at `contact_pitch` intervals:

```
|  o  |  o  |  o  |  o  |  o  |  o  |  o  |
|=====|=====|=====|=====|=====|=====|=====|  <- ring segment
```

- Via/contact type determined by `ring_type` and layer
- Contacts land on the ring metal layer
- Deep N-well rings use stacked contacts (LI + M1) for body tie

## Algorithm: insert()

1. Compute outer bbox = region + guard_ring_width + guard_ring_spacing
2. Compute inner bbox = region + guard_ring_spacing
3. Validate inner bbox > region (ring has positive width)
4. Generate donut segments (4 sides)
5. Place contacts at pitch along each segment
6. Register segments with DRC checker (if drc != null)
7. Return GuardRingIdx

## Algorithm: insertWithStitchIn()

For rings that overlap existing metal (e.g., shared VSS rail):

1. Compute normal ring geometry
2. For each overlapping region, split ring into segments with gap
3. Add contacts on both sides of each gap (stitch-in contacts)
4. Gap width = guard_ring_spacing
5. Set `has_stitch_in = true`

## Die Edge Clipping

If outer bbox extends beyond die edge:
- Clip outer bbox to die edge
- Inner bbox remains unclipped
- Warning logged for each clipped edge
- Ring still provides partial enclosure on remaining sides

## Deep N-Well Merge

When two analog blocks have adjacent deep N-well rings:
1. Query spatial index for overlapping deep N-well regions
2. Merge into single large outer bbox
3. Inner bbox = union of all inner bboxes
4. Result is a single combined ring

## Edge Cases

| Case | Handling |
|------|----------|
| Ring inner dimension <= 0 | Error: `RingTooNarrow` |
| Ring width < min_width | Error: `RingWidthViolation` |
| No space for contacts | Warning: contacts skipped on narrow segments |
| Overlaps existing ring of same net | Merge geometries |
| Overlaps existing ring of different net | Error: `RingNetConflict` |

## Dependencies

- Phase 1 (AnalogRouteDB, NetIdx)
- Phase 2 (InlineDrcChecker) — used to register ring geometry
- Core types (Rect, WireRect) — from inline_drc.zig

## Exit Criteria

- [ ] `insert()` produces complete enclosure (4 sides + contacts)
- [ ] `insertWithStitchIn()` produces enclosure with gaps at overlaps
- [ ] Die edge clipping prevents rings from extending outside die bbox
- [ ] Contact pitch is honored along all segments
- [ ] All ring segments pass DRC (no shorts or spacing violations)
- [ ] Deep N-well rings merge correctly when adjacent
