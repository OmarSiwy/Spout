# Spout LVS Diagnosis

**Date:** 2026-04-16
**Analyst:** Static read of HEAD (`721e29f`), no build/run available
**Target:** `diff_pair` benchmark → `LVS=✓`, `DRC=0`, minimal PEX

---

## 0. Read this first

### 0.1 What's verifiably true in HEAD right now

I verified every claim below by reading code, not PROGRESS.md. PROGRESS.md's two headline fixes are **already applied**:

| PROGRESS.md fix                                                          | State in HEAD                          |
| ------------------------------------------------------------------------ | -------------------------------------- |
| Body_tap at `x_tap = x` (gate left edge) in `writeMosfetGeometry`        | ✅ Applied — `gdsii.zig:707`           |
| Same fix in `writeMosfetGeometryFingered`                                | ✅ Applied — `gdsii.zig:841`           |
| Body terminal x-offset `0.0` in `pin_edge_arrays.zig`                    | ✅ Applied — `pin_edge_arrays.zig:147` |
| Body terminal x-offset `0.0` in `MultiLayerGrid.markDeviceObstacles`     | ✅ Applied — `grid.zig:427, 464`       |
| Body terminal x-offset `0.0` in legacy `RoutingGrid.markDeviceObstacles` | ✅ Applied — `grid.zig:679, 715`       |
| `via_pair: usize = lo` in `writeRoutes`                                  | ✅ Applied — `gdsii.zig:373`           |

LVS still fails, so **the root cause is not what PROGRESS.md says it is**. PROGRESS.md's concrete coordinate trace (`cx=0.135µm`) doesn't even correspond to diff_pair (which has `w=2u→cx=1.0µm` or `w=4u,m=2→cx=2.0µm`). Treat PROGRESS.md as a stale witness.

### 0.2 How LVS actually runs

`python/main.py:446` → `run_klayout_lvs` in `python/tools.py:91`. KLayout reads the Spout-generated GDS, runs sky130's `.lylvs` script to extract a netlist from geometry + TEXT labels, then diffs against the `.spice` schematic. **Spout's internal `LvsChecker.compareNetConnectivity` (`src/characterize/lvs.zig:242`) is not what the `LVS=✗` indicator reflects** — that indicator comes from KLayout.

This means: LVS sees only **shapes + TEXT labels**, never Spout's internal pin table. Any disagreement between Spout's belief about connectivity and the actual drawn geometry is invisible until LVS.

---

## 1. Severity-ranked bug list

Tiers: **S0** = blocks LVS outright; **S1** = high-probability contributor; **S2** = latent, likely to bite other benchmarks; **S3** = code-health / cleanup.

### S0-1 — Silent drops in `emitLShapeGridAware` (no error, no retry, no diagnostic)

**File:** `src/router/detailed.zig:665-702`

There are **four** silent drop branches:

```zig
// L667-674 (vertical): if M2 blocked AND M3 blocked
//   → no route emitted, no error, no counter, nothing
// L675-684 (horizontal): if M1 AND M2 blocked
// L686-694 (L-shape horizontal leg): if M1 AND M2 blocked
// L696-701 (L-shape vertical leg): if M2 AND M3 blocked
```

Each has the comment `// else: skip to prevent shorts.` or `// else: skip — no free path (prevents shorts)`. When `isSpanFree` returns false on all tried layers, the function returns silently, producing no routing geometry for that Steiner edge.

**Why this almost certainly breaks diff_pair:**

- `VSS` has the highest priority (power net), so it routes first with no contention. No drops.
- `tail` routes next (short HPWL, three pins at `cx` column of M1/M2/M3).
- In diff_pair the `tail` net connects M1.source, M2.source, M3.drain — all at `y = py - 0.13` or `py + 0.28`. Their Steiner decomposition creates short segments that run vertically in x-columns where VSS already lives (M3.source is at the same `cx` as M3.drain since `m=2` only scales width).
- If A\* finds a path but it fails the **x-deviation check** at `detailed.zig:341-352`, it falls back to `emitLShapeGridAware`.
- There, `isSpanFree` on M1/M2/M3 returns false because VSS claimed those cells → the Steiner edge is dropped silently.
- Result: `tail` is fragmented. That's exactly the "3 isolated internal nets" symptom PROGRESS.md describes.

**Fix (minimum):**

```zig
// Add counters to DetailedRouter struct:
lshape_dropped_vert: u32 = 0,
lshape_dropped_horiz: u32 = 0,
lshape_dropped_l_horiz: u32 = 0,
lshape_dropped_l_vert: u32 = 0,

// In each "// else: skip" branch, increment the counter AND log:
} else {
    self.lshape_dropped_vert += 1;
    dbgPrint("L-DROP vert net={} pos=({},{})->({},{}) m2_free={} m3_free={}\n",
        .{ net.toInt(), gx1, gy1, gx2, gy2, m1_free, false });
}
```

**Fix (proper):** Add a third-tier fallback that rips up lower-priority nets or jumps to M4/M5. A silent drop should be a runtime-level error that propagates up and fails the routing stage _loudly_ — not silently producing broken GDS.

---

### S0-2 — `writeNetLabels` labels the first route segment, even if that segment is electrically isolated from the rest of the net

**File:** `src/export/gdsii.zig:1201-1226`

```zig
// Pass 1: label the first non-degenerate segment for each net
for (0..n) |i| {
    const net_idx = r.net[i].toInt();
    if (labelled[net_idx]) continue;
    // ... writes label at midpoint of segment i, sets labelled[net_idx]=true
}
```

If a net is physically fragmented (which happens due to S0-1), this labels **one** fragment. The other fragments are nameless from KLayout's view — they become `$4`, `$11`, `$17`. LVS reports: "net `tail` is connected to these pins, but also there are these unnamed floating fragments — mismatch."

This is why the PROGRESS.md symptom looked like "isolated nets." It's not just a routing failure; **the labeling strategy amplifies the reporting**. One route drop = at least one extra unnamed fragment reported.

**Fix:** Label every route segment of every named net, not just the first. The sky130 LVS flow is tolerant of multiple labels on the same net — they all just associate with the same geometric net. Also add a label at **every pin position** (don't stop at "first route midpoint"), so that even degenerate or missing-route cases still have the pin identified.

```zig
// Pass 1: label EVERY segment of every named net
for (0..n) |i| {
    const net_idx = r.net[i].toInt();
    if (net_idx >= net_names.len) continue;
    const name = net_names[net_idx];
    if (name.len == 0) continue;
    // ... write label at midpoint, DON'T gate on `labelled[]`
}

// Pass 2: also label at every pin position (not just "nets with no routes")
for (0..pn) |i| {
    const net_idx = p.net[i].toInt();
    // ... always write a label at (dev_pos + pin_offset)
}
```

**Cost:** a few extra TEXT records per net. Negligible.
**Benefit:** even when S0-1 drops a segment, at least the label travels with pin positions, and KLayout sees the net correctly _where it was successfully routed_. This turns "LVS=✗ on everything" into "LVS=✗ only on the specific pin-to-pin connection that's physically broken" — easier to diagnose.

---

### S0-3 — LI-side landing pad of an LI↔M1 via is sized by M1's `min_width`, not LI's

**File:** `src/export/gdsii.zig:404-410`

```zig
const lo_pdk = @as(usize, lo) -| 1;  // saturating subtract
const hi_pdk = @as(usize, hi) -| 1;
const lo_mw_half: i32 = @intFromFloat(@round(pdk.min_width[lo_pdk] * scale * 0.5));
```

`pdk.min_width[0]` is **M1's min_width (0.14µm)**, not LI's (`li_min_width = 0.17µm` per `pdks/sky130.json:14`). When `lo = 0` (route-layer 0 = LI ↔ M1 transition), `lo_pdk = 0` (saturating), so the LI pad is sized with 0.14µm instead of 0.17µm. The written LI pad (on layer 67/20) can fail sky130's LI min_width DRC rule.

Also: `hi_pdk = hi -| 1`. For a M1↔M2 via (lo=1, hi=2), `hi_pdk = 1` → M2's min_width 0.14µm → but sky130's M2 `min_width` is actually 0.14µm too per the json. OK. For M2↔M3 (lo=2, hi=3), `hi_pdk=2` → `min_width[2] = 0.14µm`, but sky130's M3 min_width is actually different in reality (0.3µm per the PDK tech). Look at `pdks/sky130.json:8`: `"min_width": [0.14, 0.14, 0.14, 0.30, 0.30, ...]`. `min_width[3]` (M4) = 0.30µm. So for M3↔M4 via (lo=3, hi=4), `hi_pdk=3` → 0.30µm. But `min_width[2]` = 0.14µm, which is wrong for M3 — sky130 M3 min_width is actually 0.3µm in real rules. Let me not guess what the right PDK values are; what I can say is: **the index arithmetic has a saturating-subtract bug when `lo=0` specifically, sizing LI pads with M1 rules.**

**Fix:**

```zig
// For an LI↔M1 via, the LI pad needs pdk.li_min_width, not pdk.min_width[0].
const lo_mw_half: i32 = if (lo == 0)
    @intFromFloat(@round(pdk.li_min_width * scale * 0.5))
else
    @intFromFloat(@round(pdk.min_width[lo - 1] * scale * 0.5));
const hi_mw_half: i32 = @intFromFloat(@round(pdk.min_width[hi - 1] * scale * 0.5));
```

(Check whether `PdkConfig` exposes `li_min_width`; it does according to `sky130.json:14`, but may need to be added to the Zig `PdkConfig` struct.)

**LVS impact:** probably secondary, but LI pad below min_width can fail DRC, and if extraction is strict, an LI pad that doesn't satisfy `li_min_area` (0.0561 µm², per json line 15) might not be recognized as a connection.

---

### S0-4 — `PinAccessDB.build` never checks if access points are routable

**File:** `src/router/pin_access.zig:38-110`

The code enumerates 5 candidate APs per pin (center + 4 neighbors), filters by Manhattan distance `< 2 * metal_pitch + 0.01` — and that filter is effectively useless because all 4 neighbors are exactly `1 * pitch` away, which always passes. **No check against grid state.** The "center AP" is assumed routable.

**Then `resolveEndpoint` (detailed.zig:382) returns the first cost-0 AP**, which is always the center. If the center cell happens to be `.blocked` (e.g., because two devices are close enough that one device's Pass-1 keepout shadowed another device's pin), A\* gets `src`/`tgt` nodes that are blocked and fails immediately, triggering the silent-drop fallback chain.

Worse: the `endpoint_blocked` check in `routeNet` at lines 330-333 detects when the endpoint is owned by a different net, but not when it's **unconditionally blocked**. If the cell is `.blocked` (not `.net_owned`), the check doesn't fire, A\* runs, finds no path because the endpoint is unreachable, and we fall through to fallback with `raw_path_opt = null`.

**Fix:**

```zig
// In PinAccessDB.build, filter out APs whose cell state is blocked:
for (candidates.items) |ap| {
    const cell = grid.cellAtConst(ap.node);
    if (cell.state == .blocked) continue;  // can't route to it
    // Also: prefer APs owned by this pin's net, then free cells, then skip .blocked
    try valid.append(allocator, ap);
}
```

And in `resolveEndpoint`, prefer APs whose ownership matches the net being routed:

```zig
// Prefer: (1) net-owned cells matching our net, (2) free cells, (3) any cost-0 AP
for (aps) |ap| {
    const cell = grid.cellAtConst(ap.node);
    if (cell.state == .net_owned and cell.net_owner.toInt() == net_id) return ap.node;
}
// ... fall through to "first free", then "first cost-0"
```

---

### S1-1 — `endpoint_blocked` check in `routeNet` uses stale grid ownership

**File:** `src/router/detailed.zig:328-335`

```zig
const src_cell = grid.cellAtConst(src);
const tgt_cell = grid.cellAtConst(tgt);
const endpoint_blocked =
    (src_cell.state == .net_owned and src_cell.net_owner.toInt() != net.toInt()) or
    (tgt_cell.state == .net_owned and tgt_cell.net_owner.toInt() != net.toInt());
const raw_path_opt = if (endpoint_blocked) null else try astar.findPath(...);
```

**Problem:** `markDeviceObstacles` Pass-2 (grid.zig:437-495) un-blocks keepout cells for the pin's net. But for pins whose keepouts overlap **another pin's keepout**, the keepout is owned by whichever pin was processed last. If M3.body (VSS) and M3.source (VSS) keepouts overlap M3.drain (tail) keepout, the overlap cell is owned by VSS (last write wins based on pin iteration order). When routing tail, `endpoint_blocked` sees tail's target cell owned by VSS → fires → A\* skipped → fallback → silent drop.

**Fix:** The un-blocking logic should preserve the pin's own net ownership for the pin's **center cell** specifically, even if another net's keepout writes over it. Do a final pass that re-applies pin-center ownership after keepout un-blocking:

```zig
// Pass 3 (existing, grid.zig:500-514): un-block M1 cells at pin positions.
// Change: unconditionally set net_owner to pins.net[p], even if .net_owned.
if (pins) |pd| {
    for (0..pin_len) |p| {
        // ...
        const cell = self.cellAt(node);
        cell.state = .net_owned;
        cell.net_owner = pd.net[p];  // force — always this pin's net
    }
}
```

---

### S1-2 — x-deviation check too aggressive, forces fallback needlessly

**File:** `src/router/detailed.zig:341-352`

```zig
const li_pitch = grid.layers[0].pitch;
const x_lo = @min(src_wx, tgt_wx) - li_pitch;
const x_hi = @max(src_wx, tgt_wx) + li_pitch;
for (p.nodes) |nd| {
    const wx = grid.nodeToWorld(nd)[0];
    if (wx < x_lo or wx > x_hi) break :blk false;
}
```

Margin is ONE M1 pitch (0.34µm). This rejects ANY A* path that needs more than one pitch of horizontal detour. For tightly-packed analog devices, a legitimate route around a blockage often requires 2-3 pitches of detour. The result is forced fallback for routes that A* actually solved correctly.

**Why this was probably added:** to avoid A\* routing to the wrong contact on a close neighbor device. But the proper way to ensure that is to make pin access points sticky (use `PinAccessDB` with weighted cost) rather than filter on geometric bounding box.

**Fix:** Either remove the check entirely (trust A\* if it found a path to the right GridNode), or make the margin adaptive to HPWL:

```zig
const hpwl = @abs(tgt_wx - src_wx) + @abs(tgt_wy - src_wy);
const margin = @max(li_pitch, hpwl * 0.25);  // allow 25% detour
```

---

### S1-3 — M3's `m=2` produces a single wide device (8µm), which geometrically places the body_tap very far from the S/D column

**File:** `src/export/gdsii.zig:624` (`writeMosfetGeometry`)

M3 in diff_pair: `w=4u, l=0.15u, m=2`. In the current code, `mult` multiplies _width_ (`w_scaled = w_base * mult = 8.0µm`). So M3 is drawn as a single 8µm-wide device, not 2× 4µm-wide devices.

**Issues with this:**

1. The 8µm-wide device has `cx = x + 4.0µm`. The body_tap is at `x_tap = x` (far left). The S/D pins are at `cx = x + 4.0µm`. That's a **4µm gap** between the body contact and the S/D M1 pads — much larger than for M1/M2. This means VSS's body_tap contact is in a very different column from M3's S/D contacts.
2. **The single LICON and MCON contacts (lines 647-675) are only 170nm wide** but sit in the middle of a 8µm-wide diffusion. Current flow through this single tiny contact is DRC-legal but electrically implausible. sky130 nfet_01v8 model expects scaled contact arrays.
3. **More importantly for LVS:** the LI pad at S/D is 350nm wide (`li_half=175nm`). That's fine for connecting ONE route. But if `m=2` is supposed to be two parallel devices sharing S/D, the LVS matcher sees ONE device of W=8 vs TWO devices of W=4 — and nfet_01v8 is typically modeled with `m` as a multiplier (so W_effective = W \* m), not as separate devices. KLayout's extractor might or might not correctly reverse-engineer this. Check the KLayout nfet device extraction rules.

**Verification needed:** Check the extracted SPICE from KLayout and see if M3 comes out as `nfet W=8u m=1` or `nfet W=4u m=2` — if the former, LVS sees a mismatch with schematic's `W=4u m=2`. If the spice parser folds `m=2` into `W*=2`, this isn't a problem.

**Fix if problematic:** Actually multi-finger (`fingers=2`) instead of multiplied width, OR tell the geometry writer to emit `m=2` as two side-by-side device bodies, OR adjust the extracted-spice interpretation to match.

---

### S1-4 — `commitPath` may emit vias at wrong positions across multi-transition paths

**File:** `src/router/detailed.zig:436-470`

```zig
while (i < path.nodes.len) : (i += 1) {
    const prev = path.nodes[i - 1];
    const curr = path.nodes[i];
    if (curr.layer != prev.layer) {
        // Emit run segment, then emit via at prev position.
        if (i - 1 >= segStart) {
            try self.emitSegment(grid, path.nodes[segStart], prev, net, pdk, drc);
        }
        const pos = grid.nodeToWorld(prev);
        // ... appends zero-length marker at (wx, wy)
        try self.routes.append(lowerLayer + 1, wx, wy, wx, wy, viaWidth, net);
        segStart = i;
    } else if (i == path.nodes.len - 1) {
        try self.emitSegment(grid, path.nodes[segStart], curr, net, pdk, drc);
    }
}
```

**Bug:** `self.routes.append(lowerLayer + 1, ...)` records the via as a zero-length segment on the **upper** metal (route-layer index `lowerLayer + 1` where `lowerLayer` is the grid index of the lower of prev/curr). But the comment at `gdsii.zig:362` says "zero-length segments mark via positions emitted by commitPath". The `writeRoutes` logic detects vias by seeing **two different layers in consecutive route segments** (`prev_idx != route_layer_idx`). So the presence of the zero-length marker on the upper layer isn't what triggers the via; it's the layer transition itself.

**What actually matters:** the sequence of route segment layers. After `commitPath`:

```
segStart=0 seg (layer0) → marker (layer1) → segStart=i seg (layer1) → marker (layer0) → ...
```

Wait — `commitPath` on a path like [L0, L0, L1, L1, L2, L2] produces:

1. `emitSegment` from 0 to 1 (layer 0)
2. `routes.append(layer=1, x, y, x, y, ...)` — zero-length on layer 1 (the upper of the 0↔1 transition)
3. `segStart = 2`
4. `emitSegment` from 2 to 3 (layer 1)
5. `routes.append(layer=2, x, y, x, y, ...)` — zero-length on layer 2
6. `segStart = 4`
7. At `i = 5` (end of path), emit 4-to-5 (layer 2)

So the route array has layer sequence `[0, 1, 1, 2, 2]`. `writeRoutes` walks this, tracking `prev_layer_idx`:

- i=0, layer=0: prev=null, emit PATH on LI (layer 67/20)
- i=1, layer=1: prev=0, `lo=0 hi=1`, emit mcon via + pads; zero-length → skip PATH
- i=2, layer=1: prev=1, no transition; emit PATH on M1
- i=3, layer=2: prev=1, `lo=1 hi=2`, emit via1 + pads; zero-length → skip PATH
- i=4, layer=2: prev=2, no transition; emit PATH on M2

OK this actually looks right. The comment at `gdsii.zig:362` is correct: zero-length transitions do emit vias because the layer changed. Hypothesis weakening — this path seems fine.

**But:** `commitPath` line 447: `if (i - 1 >= segStart)`. With `i = 1` and `segStart = 0`, this is `0 >= 0 = true`, so we call `emitSegment(nodes[0], nodes[0])` — a single-node "segment." `emitSegment` at line 489-495 handles this with `x1=x2=posA[0]`, `y1=y2=posA[1]`. Then at line 503: `if (x1 != x2 and y1 != y2)` — false. Line 508: `self.routes.append(routeLayer, x1, y1, x1, y1, width, net)` — appends a zero-length M1 stub at the source pin. Good, this is what the gdsii comment expects for via detection.

So the chain works... IF the grid `worldToNode` → `nodeToWorld` round-trip preserves positions to within the routing tolerance. Which brings us to:

---

### S1-5 — Grid tracks are displaced from device pin positions by up to `pitch/2`, causing route-to-pad misalignment

**File:** `src/router/grid.zig:47-74` (`LayerTracks.init`, `worldToTrack`, `trackToWorld`)

Track 0's world position is `origin + offset = bb_min + pitch/2`. A pin at world position `p` snaps to track `round((p - origin - offset) / pitch)`, then back-converts to `origin + offset + idx * pitch`. **The round-trip offset can be up to `pitch/2`**:

For M1 cross-tracks (X direction, using M2's pitch = 0.34µm):

- `bb_xmin = min(device_positions) - 10µm` (margin per `grid.zig:136, 153`)
- If device at `x=0`, source pin at `x = 0 + w/2 = 1.0µm`, track offset is `0.17µm`, origin is `-10µm`.
- `rel = 1.0 - (-10) - 0.17 = 10.83µm`, idx = `round(10.83/0.34) = 32`, snapped_x = `-10 + 0.17 + 32*0.34 = 1.05µm`. Offset = 0.05µm. OK, within the 0.125µm M1 pad half-width.

But this is **fragile**: change the margin, change the layout, and the snap alignment shifts. And critically:

- M1 pad half-size = 125nm (computed from `licon_size/2 + licon_li_enc = 85+90 = 175` for LI pad, but actual M1 pad = `mcon_half + m1_pad_enc = 85 + 40 = 125nm`).
- M1 pad in x extends `[cx-125, cx+125]` = 250nm wide.
- If snap offset > 125nm, route endpoint lands outside the pad entirely. **No electrical connection.**
- For M1 cross-pitch = 0.34µm, max snap offset is 170nm. **Max > 125nm → possible disconnect.**

**This is a real alignment problem.** Whether it hits on diff_pair depends on the placer's exact coordinates (which depend on device size, margin, spacing). It could explain "sometimes LVS passes, sometimes it doesn't" across benchmark variants.

**Fix:** Snap device placements to grid tracks _first_, then derive pin positions from the snapped device origin. OR: add post-routing "stitching" wires from the grid-snapped route endpoints to the physical pin positions (a short LI/M1 jumper that always overlaps both).

The cleanest option: in `MultiLayerGrid.init`, compute `bb_xmin/bb_ymin` so that track 0 aligns to a device pin column. E.g., pick `bb_xmin = first_device_x - margin_rounded_to_pitch`.

---

### S1-6 — Legacy `RoutingGrid.markDeviceObstacles` still uses hardcoded `sd_contact_y = 0.13` and `body_tap_y = 0.70`

**File:** `src/router/grid.zig:659-661`

```zig
const sd_contact_y: f32 = 0.13;
const gate_contact_x: f32 = 0.20;
const body_tap_y: f32 = 0.70;
```

The `MultiLayerGrid` version and `pin_edge_arrays.computePinOffsets` both compute these per-device from `effectiveSdExtension(l)`. For `l=0.15µm` the constants happen to match. But for any `l ≥ 0.26µm` the per-device formula gives a different value, and the hardcoded legacy grid misplaces keepouts by the delta.

**When does this matter for LVS?** Only if some code path constructs a `RoutingGrid` (legacy) instead of `MultiLayerGrid`. Search usage:

```bash
grep -rn "RoutingGrid.init\|RoutingGrid{" src/
```

If any router (matched, shield, analog) uses legacy, those paths misalign. Even if diff_pair doesn't hit them, other benchmarks will.

**Fix:** DRY the sd/body offset computation into a helper in `layout_if.zig`:

```zig
pub fn mosfetGeometryOffsets(l_um: f32) struct { sd_contact_y: f32, body_tap_y: f32 } {
    const raw_sd = @max(0.26, 0.39 - l_um);
    const eff_sd_ext_um = @ceil(raw_sd / 0.002) * 0.002;
    return .{
        .sd_contact_y = eff_sd_ext_um * 0.5,
        .body_tap_y = eff_sd_ext_um + 0.44,
    };
}
```

Call it from all four sites (multi-layer Pass 1, multi-layer Pass 2, legacy Pass 1, legacy Pass 2, plus `pin_edge_arrays`).

---

### S1-7 — `pinNetForTerminal` returns first match only (O(n²) and ambiguous for duplicates)

**File:** `src/router/grid.zig:844-852`

```zig
fn pinNetForTerminal(pins: *const PinEdgeArrays, dev_idx: u32, terminal: TerminalType) ?u32 {
    for (0..pin_len) |p| {
        if (pins.device[p].toInt() == dev_idx and pins.terminal[p] == terminal) {
            return pins.net[p].toInt();
        }
    }
}
```

If `(device, terminal)` appears twice (because the spice parser registered M3's body twice, or because `m=2` caused double-registration), only the first net is returned. Pass-2 un-blocks cells for only that net. The second net's body connection is left blocked → LVS misses that connection.

**Verification:** for diff_pair, print `pins` contents after `computePinOffsets`:

```
dev=0 term=body net=?  (M1.body → VSS)
dev=0 term=source net=?  (M1.source → tail)
...
dev=2 term=body net=?  (M3.body → VSS)
dev=2 term=body net=?  (maybe duplicate?)
dev=2 term=source net=?  (M3.source → VSS)
```

If duplicates exist, determine if they should be merged at parse time or if Pass-2 should loop `all_matches` rather than return on first.

**Fix (conservative):**

```zig
// Un-block for ALL matching pins (most pins have 1 match; loop doesn't hurt)
fn unblockAllPinsForTerminal(grid: ..., pins: ..., dev_idx, terminal, ...) void {
    for (0..pin_len) |p| {
        if (pins.device[p].toInt() == dev_idx and pins.terminal[p] == terminal) {
            const net_id = pins.net[p].toInt();
            // un-block this net's keepout
        }
    }
}
```

---

### S1-8 — Pass-1 keepout un-block (grid.zig:482-492) uses `worldToNode` with `layer=0`, but only un-blocks on M1 — vertical routing layers (M2/M3) are never un-blocked at pin positions

**File:** `src/router/grid.zig:476-492`

```zig
const nd_min = self.worldToNode(0, abs_x - keepout, abs_y - keepout);
const nd_max = self.worldToNode(0, abs_x + keepout, abs_y + keepout);
// ... iterate a_lo..a_hi, b_lo..b_hi, ONLY on layer 0:
const c = self.cellAt(.{ .layer = 0, .track_a = a, .track_b = b });
```

**Problem:** tail-net routing often needs M2 to jump over a blockage. The M2 cells at the pin position are still `.blocked` from Pass-1 (`markWorldRect(...)` at line 384 blocks only layer 0 though — let me re-check). Actually Pass-0 blocks only M1 (layer 0). But Pass-1 keepout blocking at lines 432-433 also only blocks layer 0.

Re-reading: `self.markWorldRect(abs_x - keepout, abs_y - keepout, abs_x + keepout, abs_y + keepout, 0)` — last arg `0` means only layer 0. OK so **only M1 is blocked**. M2 and M3 are untouched by pin keepouts. That means M2/M3 should be freely routable at any xy — so the "M2/M3 blocked" case in `emitLShapeGridAware` can only arise from **prior nets' routes** claiming those cells via `claimNodeSpan` or `claimCell`.

This reframes S0-1: the silent drops happen when **VSS** claimed M2/M3 cells in a column that `tail` needs. Since VSS routes first, it takes the M2/M3 over the body_tap column — and if `tail` needs that column (e.g., because the Steiner tree routes a vertical segment there), tail has no recourse.

**Fix:** change net ordering. Power nets first means they grab "first-class" routes, but they don't need M3 (they should prefer M1 because they carry DC only). Force power nets to prefer lower layers:

```zig
// In routeNet, for power nets, bias A* cost toward M1/M2 with high M3 penalty.
// Better: route power on "power-layer" (some PDKs reserve a thick M layer).
```

Alternatively: route signal (tail) **before** power (VSS), since signal has fewer pins. Then VSS can work around tail's claims (VSS has more pins and more flexibility). This inverts the "power first" heuristic.

---

### S2-1 — Zero-length via markers might get sorted/reordered away from their layer-transition position

**File:** `src/core/route_arrays.zig` (haven't read fully, but) — the `RouteArrays` might sort or deduplicate segments before `writeRoutes` iterates them. If zero-length markers get sorted by xy, they could end up adjacent to non-transitioning segments and confuse `writeRoutes`'s layer-transition detector.

**Verify:** search for `sort`, `dedup`, `append` in `src/core/route_arrays.zig`.

**Fix:** if reordering occurs, make via markers explicit (e.g., a separate `vias` array) rather than encoding them as zero-length segments.

---

### S2-2 — `mapViaLayer` only handles single-step transitions; multi-step is silently dropped

**File:** `src/export/gdsii.zig:1286-1304`

```zig
if (hi - lo != 1) return .{ .layer = 0, .datatype = 0 };
```

Return value `(0, 0)` is a sentinel that `writeRoutes:371` checks: `if (via_layer.layer != 0 and hi - lo == 1)`. So the check is belt-and-suspenders here, it returns 0 → gate rejects → no via.

**But then:** if a route has layer sequence `[M1, M1, M3, M3]` (skipping M2), no via is emitted. The route is electrically broken at the layer jump. `commitPath` at line 442 only checks `curr.layer != prev.layer`, not `abs(curr.layer - prev.layer) == 1`. A\* can theoretically produce multi-layer jumps if the grid allows `via-across-2-layers` moves (check `astar.zig`).

**Verify:** does A\* produce consecutive path nodes differing by more than 1 in layer?

```bash
grep -n "layer\s*+\s*1\|layer\s*-\s*1\|\\.layer\s*=" src/router/astar.zig
```

**Fix:** either constrain A\* to single-layer jumps, or have `commitPath` insert intermediate-layer stubs at every `layer_diff > 1` transition.

---

### S2-3 — `isSpanFree` uses `cellAt(.{.layer=l, .track_a=a, .track_b=b})` iteration that assumes square grid, breaks on layers with different track_a/track_b counts

**File:** `src/router/detailed.zig:572-587`

```zig
const node_a = grid.worldToNode(layer, from_x, from_y);
const node_b = grid.worldToNode(layer, to_x, to_y);
const a_lo = @min(node_a.track_a, node_b.track_a);
// ... iterate track_a and track_b independently
```

But `worldToNode` on a horizontal layer maps `(x, y)` to `(track_a=y, track_b=x)`. On a vertical layer, `(track_a=x, track_b=y)`. `isSpanFree` is called with `(from_x, from_y, to_x, to_y)` without knowing the layer's orientation — so `a_lo..a_hi` means different things per layer. For an L-shape vertical leg (`x1=x2`, `y1≠y2`), on a horizontal layer the y-tracks are `track_a` → iteration matches. On a vertical layer, x-tracks are `track_a` → `a_lo==a_hi` (since x doesn't change) and `b_lo..b_hi` is the y-range → also works.

Actually this seems OK on reflection. The `worldToNode` does the direction-aware mapping internally. The iteration just iterates the Cartesian grid in track space. Ignore this — false alarm.

---

### S2-4 — `writeMosfetGeometry` doesn't emit `li_min_area` compliant LI pads on bare pins

**File:** `src/export/gdsii.zig:655-662`

LI pad `li_half = 175nm` → pad is 350×350nm = 122500nm² = 0.1225µm². PDK `li_min_area = 0.0561µm²`. OK, pad is well above min_area for a single contact.

But: for a multi-finger device, each contact has its own LI pad. For a long run of contacts, if they don't overlap, each is a separate LI island. Each needs ≥0.0561µm². 350×350 is fine.

No bug here. Skip.

---

### S2-5 — `writeMosfetGeometry` emits **ONE** source contact and **ONE** drain contact regardless of gate width

**File:** `src/export/gdsii.zig:646-675`

For a 2µm-wide NMOS, there's a single 170nm LICON in the middle of a 2µm S/D diffusion. The LI pad is 350nm, covering only a tiny fraction of the diffusion. The gate can draw current from the whole diff region, but the terminal resistance is dominated by the single contact. More importantly for this diagnosis:

- The M1 landing pad is only 250nm wide. The router can only "hit" a single 250nm target in a 2µm-wide device.
- For M3 (w=8µm scaled), there's one 170nm contact at cx=4µm. The router has a single 250nm target window to hit — or it misses.

Given the grid-snapping issue (S1-5, up to 170nm x-error), the router can easily miss the 250nm pad on M3 because `cx=4.0µm` may snap to some track 170nm away.

**Fix:** emit **multiple** LICON/MCON/M1 pads along the diffusion, at track-aligned positions. This both lowers contact resistance AND gives the router multiple landing options.

---

### S3-1 — `cross_layers[0]` uses M2's pitch (0.34µm), but M1's own pitch is also 0.34µm. If PDK differs (e.g., M1 pitch ≠ M2 pitch), the cross-pitch assumption breaks.

**File:** `src/router/grid.zig:172-187`

```zig
const cross_idx: u8 = if (l + 1 < num_layers) l + 1 else if (l > 0) l - 1 else l;
const cross_pitch = pdk.metal_pitch[cross_idx];
```

Cross direction uses **next layer's pitch**. On sky130 M1 is horizontal (y-tracks), cross is x-tracks with M2's pitch (coincidentally also 0.34µm). But conceptually cross-tracks for M1 should use **M1's own pitch** (since you can place M1 vertical segments at M1's minimum x-spacing). Using M2's pitch under-utilizes M1 capacity.

For sky130 this is a no-op (both are 0.34). For other PDKs it'd matter. Not an LVS bug — efficiency only.

---

### S3-2 — Debug prints left in code (per PROGRESS.md)

PROGRESS.md lists 10+ leftover debug print sites in `detailed.zig`. Verify which are still there:

```bash
grep -n "dbgPrint\|std.debug.print\|posix.write" src/router/detailed.zig
```

Remove or convert to `Debug`-mode-only. Noise in output makes triage harder.

---

### S3-3 — `compareNetConnectivity` (lvs.zig) is unused by the actual LVS signoff

Spout's internal `LvsChecker` is a union-find comparison of the Spout-internal pin tables. KLayout is what decides `lvs_clean`. The internal check is dead code from a LVS perspective (though it could be resurrected as a pre-check before KLayout).

No action needed, but don't spend time fixing `compareNetConnectivity` to fix real LVS issues.

---

## 2. Recommended fix order (apply + test incrementally)

1. **S0-2** (Label every segment) — cheap, easy, amplifies diagnostic quality. Do first.
2. **S0-1** (Add drop counters + diagnostics) — 30 lines. Tells us which S0/S1 is actually firing.
3. **Run** `python scripts/benchmark.py -c diff_pair` with new diagnostics and capture output.
4. Based on output, apply S0-4 (PinAccessDB routability check) + S1-1 (endpoint_blocked fix) + S1-2 (relax x-deviation).
5. Re-run. If LVS=✓ for diff_pair, run full benchmark to check regressions.
6. If still failing, apply S1-5 (grid alignment) and/or S1-7 (pin duplicate handling).
7. Cleanup: S0-3, S1-3, S1-6, S2-1, S2-2.

Each step should be a separate commit so regressions are bisectable.

---

## 3. Tests I'd want you to run

### 3.1 Must-run (confirms/kills top hypotheses)

```bash
# After applying S0-1 + S0-2:
python scripts/benchmark.py -c diff_pair 2>&1 | tee /tmp/diff_pair.log

# Inspect:
grep -E "astar_ok|astar_fail|L-DROP" /tmp/diff_pair.log
# If L-DROP appears with net=tail or net=VSS, S0-1 is confirmed.
# Expected output (with current bugs):
#   astar_ok=X  astar_fail=Y  L-DROP count=Z
```

### 3.2 Verification that labels work

```bash
# Dump the GDS to ASCII so we can see TEXT records
klayout -b -r dump_gds.py -rd input=diff_pair.gds -rd output=diff_pair.txt
# (dump_gds.py is a 10-line klayout script to dump all shapes + text)

# Then verify:
grep -E "TEXT|VSS|tail|OUTP|OUTN|INP|INN|BIAS" diff_pair.txt
# Expected: one TEXT element per net name, on layer 68/5 (metal_pin[0])
# Each should be at a position that lies ON an M1 rectangle also in the file.
```

### 3.3 Post-fix regression

```bash
# Full benchmark suite to confirm no regression on circuits that currently pass:
python scripts/benchmark.py 2>&1 | tee /tmp/full.log
grep -E "LVS=✓|LVS=✗" /tmp/full.log | sort | uniq -c
# Compare to pre-fix numbers; must not regress any passing circuit.
```

### 3.4 Targeted unit tests to add

**Test: grid snapping preserves pin position within M1 pad half-width**

```zig
test "grid snap: every pin snaps to within m1_half of its true position" {
    // Build grid, iterate all pins, verify:
    //   abs(nodeToWorld(worldToNode(pin_pos)).x - pin_pos.x) < 0.125
    //   abs(nodeToWorld(worldToNode(pin_pos)).y - pin_pos.y) < 0.125
}
```

**Test: `emitLShapeGridAware` never silently drops**

```zig
test "L-shape: all-blocked case raises error, not silent drop" {
    // Set up grid with both M1 and M2 blocked between two pins.
    // Call emitLShapeGridAware.
    // Expect: either a route is emitted (on M3/M4), or an error is returned.
    // Must NOT return normally with zero new routes.
}
```

**Test: `writeNetLabels` labels every connected region**

```zig
test "labels: fragmented net gets label on every fragment" {
    // Route a net, manually remove middle segment to fragment it.
    // Verify writeNetLabels emits 2+ TEXT records for that net
    // (one per connected region).
}
```

**Test: `PinAccessDB` rejects blocked APs**

```zig
test "pin access: center AP is skipped when cell is blocked" {
    // Build grid, manually block a pin's center cell.
    // Call PinAccessDB.build.
    // Verify aps[pin_idx] doesn't contain the blocked center as cost-0.
}
```

**Test: LI-M1 via uses correct LI min_width**

```zig
test "LI via pad: LI side uses li_min_width, not m1 min_width" {
    // Write a route with LI→M1 transition, assert LI pad >= 0.17µm × 0.17µm.
}
```

---

## 4. Artifacts I need from a local run to lock in the diagnosis

Listed in priority order. Each entry specifies what I need and why.

### 4.1 (HIGHEST) The generated `diff_pair.gds` file, dumped to text

```bash
# Ask klayout to emit an ASCII dump
klayout -b -r dump_gds.py -rd input=/path/to/diff_pair.gds -rd output=/tmp/diff_pair.gds.txt
cat /tmp/diff_pair.gds.txt  # paste me the output
```

Where `dump_gds.py` is:

```python
import pya
inp = "$(input)"; out = "$(output)"
ly = pya.Layout(); ly.read(inp)
with open(out, "w") as f:
    for cell in ly.each_cell():
        f.write(f"CELL {cell.name}\n")
        for li in ly.layer_indexes():
            info = ly.get_info(li)
            for sh in cell.shapes(li).each():
                if sh.is_box():
                    b = sh.box
                    f.write(f"  BOX L={info.layer}/{info.datatype} "
                            f"({b.left},{b.bottom})-({b.right},{b.top})\n")
                elif sh.is_path():
                    p = sh.path
                    f.write(f"  PATH L={info.layer}/{info.datatype} "
                            f"w={p.width} pts={list(p.each_point())}\n")
                elif sh.is_text():
                    t = sh.text
                    f.write(f"  TEXT L={info.layer}/{info.datatype} "
                            f"({t.x},{t.y}) \"{t.string}\"\n")
```

**This tells me:**

- Are TEXT labels actually present? On which layers and at what coordinates?
- Is the geometry what `writeMosfetGeometry` is supposed to produce?
- Are there routes connecting the pins we expect, or are there gaps?
- Are vias present at layer transitions?

### 4.2 (HIGH) The full KLayout LVS report

From `main.py:451`: the `DEBUG LVS details:` block. If it's truncated at 3000 chars, raise the limit or save to a file. I need:

- The extracted netlist (KLayout writes one internally)
- The "connected" vs "expected" diff
- Per-net pin assignments

### 4.3 (HIGH) Stdout/stderr from `python scripts/benchmark.py -c diff_pair`

Full run, unfiltered. I want to see every `dbgPrint` currently in the code, every warning, every log line.

### 4.4 (MEDIUM) `astar_ok` and `astar_fail` counter values

These are struct fields on `DetailedRouter` (lines 102-103) but I don't see them printed anywhere. Add a print at the end of `routeAll`:

```zig
dbgPrint("ROUTER STATS: astar_ok={} astar_fail={}\n",
    .{ self.astar_ok, self.astar_fail });
```

and rerun.

### 4.5 (MEDIUM) Dump of `pins` table after `computePinOffsets`, for diff_pair

Either as a test harness output or a one-time debug print. Format:

```
pin[0]: dev=0 term=gate net=INP pos=(-0.20, 0.075)
pin[1]: dev=0 term=drain net=OUTN pos=(1.0, 0.28)
pin[2]: dev=0 term=source net=tail pos=(1.0, -0.13)
pin[3]: dev=0 term=body net=VSS pos=(0.0, -0.70)
... for all 3 devices ...
```

**I'm looking for:** duplicates (S1-7), missing bodies, wrong nets.

### 4.6 (MEDIUM) Magic PEX output: `diff_pair.spice`

Even if PEX isn't the priority, Magic's ext2spice-derived netlist is a second opinion on connectivity. If Magic says "connected" but KLayout says "fragmented," the issue is KLayout label-reading, not geometry. If both say fragmented, it's geometry.

### 4.7 (LOWER) Full benchmark summary

```
Circuit        DRC  LVS  Res  Cap
inv             0    ✓    0    2
nand2           0    ✓    0    5
current_mirror  ?    ?    ?    ?
diff_pair       ?    ✗    ?    9
...
```

Tells me whether the bug is diff-pair-specific or broader. Informs which hypotheses are more likely.

### 4.8 (LOWER) Placer output: device positions for diff_pair

```bash
# Whatever command dumps the placed device coordinates:
spout place diff_pair.spice --dump-positions
```

Needed for me to recompute the exact snap offsets in S1-5 and determine if grid alignment is the actual issue.

---

## 5. Open questions I can't answer from static read

1. **Does the spice parser split `m=2` into two device instances, or keep it as one device with `mult=2`?** Check `src/import/` for the netlist parser. Affects S1-3.
2. **Does A\* produce multi-layer jumps?** Check `src/router/astar.zig` movement generation. Affects S2-2.
3. **Does `RouteArrays` preserve append order or sort on insert?** Affects S2-1.
4. **What does KLayout's sky130 LVS script expect as label layer?** If it's `metal_pin[0]=68/5`, we're good. If it's `li_pin=67/5` for body connections (which are on LI), Pass-2 labels are on the wrong layer.
5. **Is the placer snapping to grid?** If not, S1-5 is an active bug.

---

## 6. Confidence summary

| Bug                                 | Confidence it's a real bug   | Confidence it's causing current LVS fail |
| ----------------------------------- | ---------------------------- | ---------------------------------------- |
| S0-1 silent drop                    | **very high**                | **very high**                            |
| S0-2 single label                   | **very high**                | **high** (amplifies)                     |
| S0-3 LI pad sized wrong             | **high**                     | medium (may cause DRC, not LVS directly) |
| S0-4 PinAccessDB unchecked          | **high**                     | **high**                                 |
| S1-1 endpoint_blocked stale         | **high**                     | **high**                                 |
| S1-2 x-deviation too tight          | **high**                     | medium                                   |
| S1-3 m=2 geometry                   | medium                       | medium                                   |
| S1-4 via in commitPath              | low (re-analysis exonerated) | low                                      |
| S1-5 grid alignment                 | **high**                     | medium                                   |
| S1-6 legacy hardcoded y             | **high**                     | low (diff_pair unaffected)               |
| S1-7 pin duplicate                  | medium                       | medium                                   |
| S1-8 M2/M3 never unblocked at pins  | **high**                     | medium                                   |
| S2-1 route reordering               | unknown                      | unknown                                  |
| S2-2 multi-layer via                | medium                       | low                                      |
| S2-5 single contact per wide device | **high**                     | medium                                   |

**Best single-bet fix order for LVS-passing diff_pair:**

1. S0-2 (label every segment, always label pin positions) — probably alone makes LVS closer to ✓
2. S0-1 + S1-1 + S0-4 (stop silent drops, fix endpoint check, filter blocked APs) — probably makes routing robust
3. S1-2 (loosen x-deviation) — probably makes A\* succeed more often
4. S1-8 (invert net ordering for power) — probably makes M2/M3 available for signals

That's the minimum viable fix set. Everything else is defense-in-depth.
