# LVS Fix Progress

**Date:** 2026-04-15
**Status:** Root cause fully diagnosed. Long-term fix identified. Not yet implemented.

---

## Current Symptom

`diff_pair` benchmark: LVS=✗, DRC=0, C=9 (some caps routed, tail net never connected).

Extracted netlist shows 3 isolated internal nets ($4, $11, $17) that should all be the `tail` net:
```
M$1 VSS  BIAS $17  VSS   ← tail device: one terminal=VSS, other=$17 isolated
M$2 $11  INN  OUTP VSS   ← diff pair:   drain=$11 isolated, source=OUTP
M$3 $4   INP  OUTN VSS   ← diff pair:   drain=$4  isolated, source=OUTN
```

---

## Root Cause (Fully Understood)

### Physical layout geometry

All device contacts (source, drain, body_tap) are placed at the SAME x = `cx = device_x + w/2`.
For diff_pair with cx=0.135µm:

| y (µm) | Net  | Terminal            |
|--------|------|---------------------|
| 7.895  | VSS  | M$1 source          |
| 8.465  | tail | M$1 drain           |
| 10.796 | VSS  | M$2 body_tap        |
| 11.366 | tail | M$2 source          |
| 14.982 | VSS  | M$3 body_tap        |
| 15.552 | VSS  | (M$3 body_tap or drain) |
| 15.962 | tail | M$3 source          |

VSS and tail contacts **interleave in y at the same x=0.135µm**. Any straight vertical metal connecting tail contacts passes through VSS contact M1 pads → short.

### Routing grid conflict

- x=0.135µm snaps to routing grid track x=0.250µm (nearest cross-track, track_b=56).
- VSS routes first (power priority). Its A* path uses multiple grid layers (LI→M1→M2) to navigate around device keepout zones between tightly-spaced contacts.
- VSS A* claims grid layer 1 (M1) and layer 2 (M2) cells at x=0.250 spanning y≈7.855 to y≈15.675.
- When tail routes, `isSpanFree(layer=1)` and `isSpanFree(layer=2)` both return false.

### Attempted workarounds (failed)

| Attempt | Why failed |
|---------|------------|
| `endpoint_blocked` check before A* | Target cell already owned by tail (claimed by previous segment's fallback), not VSS — check never fires |
| x-deviation check (reject A* detour paths) | Correctly forces tail to geometric fallback, but fallback also blocked |
| Physical-x M2 at x=0.135 | M2 at x=0.135 (width=0.14µm → x=[0.065, 0.205]) overlaps VSS M2 at x=0.250 (x=[0.180, 0.320]) → SHORT in M2 layer |

---

## Long-Term Fix: Move Body Tap Off-Center in `writeMosfetGeometry`

**File:** `src/export/gdsii.zig`, function `writeMosfetGeometry` (~L706)

Currently, the body_tap is placed at `cx` (same x as source/drain contacts). This creates the interleaving problem. Move the body_tap to the **left edge** of the device, at x = `x` (the gate left edge, NOT cx).

### Change in `writeMosfetGeometry`

```zig
// CURRENT (body_tap at cx — same x as S/D contacts):
const body_cy = y - eff_sd_ext - tap_gap - @divTrunc(tap_diff_size, 2);
const tap_half = @divTrunc(tap_diff_size, 2);
// ... all body_tap shapes written at cx ±tap_half / cx ±licon_half / cx ±mcon_half / cx ±m1_half

// PROPOSED (body_tap at left edge — x_tap = x, the gate poly left edge):
// Use x_tap = x (left edge of diff region) instead of cx.
// This separates VSS body_tap contacts from S/D contacts in x-column.
const x_tap = x;  // left edge of gate width (gate diff region starts here)
const body_cy = y - eff_sd_ext - tap_gap - @divTrunc(tap_diff_size, 2);
const tap_half = @divTrunc(tap_diff_size, 2);
// body tap diffusion at x_tap:
try writeRect(writer, tap_layer,
    x_tap - tap_half, body_cy - tap_half,
    x_tap + tap_half, body_cy + tap_half);
// body tap implant, licon, LI, mcon, M1 — all at x_tap instead of cx
```

With this change:
- S/D contacts at cx = 0.135µm → routing track x=0.250µm
- Body_tap at x_tap = x (gate left edge, e.g. x=0 for a device at x=0 with cx=w/2)

The two contact types are now at **different x-columns**. VSS (body_tap) routes at its column, tail routes at the S/D column (x=0.250). No conflict.

### Also update `writeMosfetGeometryFingered`

Same body_tap placement change is needed in the fingered variant (~L820). All body_tap shapes must move to x_tap = x (or the analogous left-edge position per finger).

### Also update `grid.zig markDeviceObstacles`

The keepout and terminal registration in `markDeviceObstacles` (L366+) computes body_tap offsets using `w_scaled * 0.5` for the x-offset (matching current cx placement). Must change `.body` terminal x-offset from `w_scaled * 0.5` to `0` (left edge):

```zig
// CURRENT:
.{ .t = .body, .ox = w_scaled * 0.5, .oy = -body_tap_y },

// PROPOSED:
.{ .t = .body, .ox = 0.0, .oy = -body_tap_y },
```

Same change in `pin_edge_arrays.zig` where body_tap x-offset is computed.

---

## Secondary Fix: via_pair Bug in `writeRoutes`

**File:** `src/export/gdsii.zig`, `writeRoutes` function (~L373)

Current code:
```zig
const via_pair: usize = if (lo == 0) 0 else @as(usize, lo) - 1;
```

This maps:
- lo=0 (LI↔M1) → via_pair=0 (mcon) ✓
- lo=1 (M1↔M2) → via_pair=0 (mcon) ✗ should be 1 (via1)
- lo=2 (M2↔M3) → via_pair=1 (via1) ✗ should be 2 (via2)

Correct:
```zig
const via_pair: usize = lo;
```

Effect: via1 landing pads shrink from 165nm half to 115nm half (using enc=30nm instead of 80nm). This also helps reduce overlap between adjacent nets' via pads.

---

## Cleanup Required (Before Merging)

Remove all debug prints added during investigation:

**`src/router/detailed.zig`**:
- `routeNet` pin dump (~L292-308)
- `A* OK` print (~L352-355)
- `A* FAIL fallback` print (~L372-374)
- `ep_check` block (~L332-342) — entire block can be removed
- `commitPath net=7` node dump (~L434-443)
- `emitLS vert` debug block in `emitLShapeGridAware` (~L681-687)
- `emitLS: physical-x M2 fallback` print (~L699)
- `M3 fallback: pure-vertical` print (~L691)
- `M3 fallback: L-shape vertical` print (~L729)
- `emitLS: BOTH BLOCKED` / `physical-x M2 fallback` prints

Remove dead code (physical-x M2 fallback) in the BOTH BLOCKED branch.

---

## Files Changed So Far (This Session — WIP, Not Clean)

| File | Status |
|------|--------|
| `src/router/detailed.zig` | Modified: x-deviation check, physical-x fallback (WIP), debug prints |
| `src/core/pin_edge_arrays.zig` | Bug fix: per-device eff_sd_ext (from prior session, keep) |
| `src/router/grid.zig` | Bug fix: per-device eff_sd_ext in keepouts (from prior session, keep) |
| `src/export/gdsii.zig` | Bug fix: via generation for zero-length markers (from prior session, keep) |

`detailed.zig` changes from this session should be **reverted to pre-session state** (except the working A* deviation check — confirm it doesn't regress other benchmarks) and the body_tap fix implemented cleanly instead.

---

## Testing After Fix

```
python scripts/benchmark.py -c diff_pair
```

Target: `DRC=0  LVS=✓`

Also run full benchmark suite to verify no regressions:
```
python scripts/benchmark.py
```

Key other circuits to check: `current_mirror`, `nand2`, `inv` — any circuit with NMOS body_taps.

---

## Key File Locations

| What | Where |
|------|-------|
| Body_tap placement (single device) | `src/export/gdsii.zig` `writeMosfetGeometry` ~L706 |
| Body_tap placement (fingered) | `src/export/gdsii.zig` `writeMosfetGeometryFingered` ~L820 |
| Body_tap keepout in grid | `src/router/grid.zig` `markDeviceObstacles` ~L464 (`.body` terminal) |
| Body_tap pin offset | `src/core/pin_edge_arrays.zig` body terminal x-offset |
| via_pair bug | `src/export/gdsii.zig` `writeRoutes` ~L373 |
| Geometric fallback | `src/router/detailed.zig` `emitLShapeGridAware` ~L678 |
| Debug prints to remove | `src/router/detailed.zig` throughout `routeNet` and `emitLShapeGridAware` |
