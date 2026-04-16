# Guard Rings and Shield Routing

**Sources:**
- `src/router/guard_ring.zig` — guard ring geometry, SoA database, contact placement
- `src/router/shield_router.zig` — shield wire generation, via drops, DRC validation

---

## Guard Rings

### Purpose

A **guard ring** is a donut-shaped diffusion or well ring placed around a sensitive analog block. It collects minority carriers injected from switching digital logic, preventing substrate noise from reaching the protected circuit. In CMOS processes, three fundamental ring types are available:

| Type | Material | Protects against | Typical use |
|---|---|---|---|
| `p_plus` (0) | P+ diffusion, licon contacts to VSS | N-substrate minority carriers | NMOS blocks |
| `n_plus` (1) | N+ diffusion, licon contacts to VDD | P-well minority carriers | PMOS blocks |
| `deep_nwell` (2) | Deep N-well implant | Substrate coupling through P-sub | Triple-well isolation |
| `composite` (3) | P+ ring + deep N-well combined | Full latchup protection | High-precision analog |

### Geometry: Donut Shape

Every ring is defined by two rectangles: an **outer bbox** (the outer edge of the ring material) and an **inner bbox** (the boundary of the protected area, i.e. the inner hole).

```
outer_x1 = region.x1 - gr_spacing - gr_width
outer_y1 = region.y1 - gr_spacing - gr_width
outer_x2 = region.x2 + gr_spacing + gr_width
outer_y2 = region.y2 + gr_spacing + gr_width

inner_x1 = region.x1 - gr_spacing
inner_y1 = region.y1 - gr_spacing
inner_x2 = region.x2 + gr_spacing
inner_y2 = region.y2 + gr_spacing
```

Where:
- `gr_spacing = pdk.guard_ring_spacing` — clearance from protected region to inside edge of ring
- `gr_width = pdk.guard_ring_width` — width of the ring band itself

The ring material occupies the area `outer - inner` (a rectangular frame). The physical width of the band on each side equals `gr_width`.

### SVG Diagram — Guard Ring Layout

```svg
<svg xmlns="http://www.w3.org/2000/svg" width="720" height="500" viewBox="0 0 720 500">
  <style>
    text { font-family: 'Inter', 'Segoe UI', sans-serif; font-size: 12px; fill: #B0BEC5; }
    .label-sm   { font-size: 10px; fill: #78909C; }
    .label-acc  { fill: #00C4E8; }
    .label-grn  { fill: #43A047; }
    .label-red  { fill: #EF5350; }
    .label-blu  { fill: #1E88E5; }
    .label-title { font-size: 15px; font-weight: 600; fill: #E0E0E0; }
  </style>

  <!-- Background -->
  <rect width="720" height="500" fill="#060C18" rx="10"/>

  <!-- Title -->
  <text x="360" y="32" text-anchor="middle" class="label-title">Guard Ring Layout — P+ ring around NMOS block</text>

  <!-- Deep N-well (outermost, purple fill) -->
  <rect x="80" y="80" width="400" height="340" fill="none" stroke="#9C27B0" stroke-width="1.5" stroke-dasharray="6 4" rx="4"/>
  <text x="488" y="250" fill="#9C27B0" font-size="11" font-family="'Inter','Segoe UI',sans-serif">Deep N-well</text>
  <text x="488" y="264" fill="#9C27B0" font-size="11" font-family="'Inter','Segoe UI',sans-serif">(outer bbox)</text>

  <!-- P+ ring band — outer bbox -->
  <rect x="120" y="120" width="320" height="260" fill="#4A1500" stroke="#EF5350" stroke-width="1.5" rx="2"/>

  <!-- P+ ring band — inner bbox (protected region + spacing) -->
  <rect x="160" y="160" width="240" height="180" fill="#060C18" stroke="#EF5350" stroke-width="1" stroke-dasharray="3 3"/>

  <!-- Protected region (the analog block) -->
  <rect x="190" y="188" width="180" height="124" fill="#0D1A2E" stroke="#1E88E5" stroke-width="2"/>
  <text x="280" y="254" text-anchor="middle" class="label-blu">NMOS</text>
  <text x="280" y="270" text-anchor="middle" class="label-blu">Analog Block</text>

  <!-- Spacing annotation (region → inner) -->
  <line x1="190" y1="250" x2="160" y2="250" stroke="#00C4E8" stroke-width="1" marker-end="url(#arrow)"/>
  <text x="115" y="246" class="label-acc" font-size="10">gr_spacing</text>

  <!-- Width annotation (inner → outer on top) -->
  <line x1="280" y1="155" x2="280" y2="120" stroke="#EF5350" stroke-width="1"/>
  <text x="250" y="114" class="label-red" font-size="10">gr_width</text>

  <!-- Ring band label -->
  <text x="132" y="146" fill="#EF5350" font-size="11" font-family="'Inter','Segoe UI',sans-serif">P+ diffusion ring</text>

  <!-- Contact dots — top row -->
  <circle cx="160" cy="132" r="3" fill="#43A047"/>
  <circle cx="188" cy="132" r="3" fill="#43A047"/>
  <circle cx="216" cy="132" r="3" fill="#43A047"/>
  <circle cx="244" cy="132" r="3" fill="#43A047"/>
  <circle cx="272" cy="132" r="3" fill="#43A047"/>
  <circle cx="300" cy="132" r="3" fill="#43A047"/>
  <circle cx="328" cy="132" r="3" fill="#43A047"/>
  <circle cx="356" cy="132" r="3" fill="#43A047"/>
  <circle cx="384" cy="132" r="3" fill="#43A047"/>
  <circle cx="412" cy="132" r="3" fill="#43A047"/>

  <!-- Contact dots — bottom row -->
  <circle cx="160" cy="368" r="3" fill="#43A047"/>
  <circle cx="188" cy="368" r="3" fill="#43A047"/>
  <circle cx="216" cy="368" r="3" fill="#43A047"/>
  <circle cx="244" cy="368" r="3" fill="#43A047"/>
  <circle cx="272" cy="368" r="3" fill="#43A047"/>
  <circle cx="300" cy="368" r="3" fill="#43A047"/>
  <circle cx="328" cy="368" r="3" fill="#43A047"/>
  <circle cx="356" cy="368" r="3" fill="#43A047"/>
  <circle cx="384" cy="368" r="3" fill="#43A047"/>
  <circle cx="412" cy="368" r="3" fill="#43A047"/>

  <!-- Contact dots — left column -->
  <circle cx="132" cy="168" r="3" fill="#43A047"/>
  <circle cx="132" cy="196" r="3" fill="#43A047"/>
  <circle cx="132" cy="224" r="3" fill="#43A047"/>
  <circle cx="132" cy="252" r="3" fill="#43A047"/>
  <circle cx="132" cy="280" r="3" fill="#43A047"/>
  <circle cx="132" cy="308" r="3" fill="#43A047"/>
  <circle cx="132" cy="336" r="3" fill="#43A047"/>

  <!-- Contact dots — right column -->
  <circle cx="428" cy="168" r="3" fill="#43A047"/>
  <circle cx="428" cy="196" r="3" fill="#43A047"/>
  <circle cx="428" cy="224" r="3" fill="#43A047"/>
  <circle cx="428" cy="252" r="3" fill="#43A047"/>
  <circle cx="428" cy="280" r="3" fill="#43A047"/>
  <circle cx="428" cy="308" r="3" fill="#43A047"/>
  <circle cx="428" cy="336" r="3" fill="#43A047"/>

  <!-- Contact annotation -->
  <text x="440" y="132" class="label-grn" font-size="11">licon contacts</text>
  <text x="440" y="146" class="label-grn" font-size="11">@ pitch</text>

  <!-- Midline annotation -->
  <line x1="160" y1="144" x2="120" y2="144" stroke="#FFC107" stroke-width="1" stroke-dasharray="3 2"/>
  <text x="60" y="148" fill="#FFC107" font-size="10" font-family="'Inter','Segoe UI',sans-serif">midline Y</text>

  <!-- Legend -->
  <rect x="535" y="85" width="160" height="150" rx="5" fill="#0D1A2E" stroke="#1E3A5C" stroke-width="1"/>
  <text x="615" y="105" text-anchor="middle" fill="#E0E0E0" font-size="12" font-family="'Inter','Segoe UI',sans-serif">Legend</text>
  <rect x="548" y="117" width="16" height="10" fill="#4A1500" stroke="#EF5350" stroke-width="1"/>
  <text x="572" y="127">P+ ring band</text>
  <rect x="548" y="135" width="16" height="10" fill="#0D1A2E" stroke="#1E88E5" stroke-width="1"/>
  <text x="572" y="145">Protected block</text>
  <circle cx="556" cy="162" r="4" fill="#43A047"/>
  <text x="572" y="166">Tap contacts</text>
  <line x1="548" y1="181" x2="564" y2="181" stroke="#9C27B0" stroke-width="1.5" stroke-dasharray="5 3"/>
  <text x="572" y="185">Deep N-well</text>
  <line x1="548" y1="201" x2="564" y2="201" stroke="#EF5350" stroke-width="1" stroke-dasharray="3 2"/>
  <text x="572" y="205">Inner bbox</text>

  <!-- outer bbox label -->
  <text x="120" y="430" class="label-red">outer bbox = region + gr_spacing + gr_width</text>
  <text x="120" y="448" fill="#EF5350" font-size="10" font-family="'Inter','Segoe UI',sans-serif">inner bbox = region + gr_spacing (donut hole)</text>
  <text x="120" y="466" class="label-grn" font-size="10" font-family="'Inter','Segoe UI',sans-serif">contacts on midline of each ring band at pitch = via_spacing[0]</text>
</svg>
```

---

## Data Structures

### `GuardRingType`

```zig
pub const GuardRingType = enum(u8) {
    p_plus    = 0,   // P+ diffusion ring (N-substrate isolation)
    n_plus    = 1,   // N+ diffusion ring (P-well isolation)
    deep_nwell = 2,  // Deep N-well ring (triple-well isolation)
    composite  = 3,  // P+ + deep N-well combined (latchup protection)
};
```

### `GuardRing` (AoS record)

```zig
pub const GuardRing = struct {
    bbox_x1, bbox_y1, bbox_x2, bbox_y2: f32,   // outer rectangle
    inner_x1, inner_y1, inner_x2, inner_y2: f32, // inner hole rectangle
    ring_type:     GuardRingType,
    net:           NetIdx,
    contact_pitch: f32,
    has_stitch_in: bool,
};
```

### `GuardRingDB` (SoA table)

12 ring columns + 3 contact columns. All fields are parallel arrays indexed `[0..len)`.

| Column | Type | Description |
|---|---|---|
| `bbox_x1/y1/x2/y2` | `[]f32` | Outer rectangle (die-clipped) |
| `inner_x1/y1/x2/y2` | `[]f32` | Inner hole rectangle |
| `ring_type` | `[]GuardRingType` | Ring classification |
| `net` | `[]NetIdx` | Connected net (VSS for P+, VDD for N+) |
| `contact_pitch` | `[]f32` | Via spacing along ring perimeter |
| `has_stitch_in` | `[]bool` | Whether gaps were cut for existing metal |
| `contacts_x/y` | `[]f32` | Flat contact position arrays |
| `contacts_ring_idx` | `[]u32` | Maps each contact to its parent ring |
| `num_contacts` | `u32` | Total contact count across all rings |

**Capacity management:** `initCapacity(n)` pre-allocates all arrays at size `n`. `append` triggers `grow(capacity*2 + 4)` when full. `grow` reallocates all 12 ring-column arrays simultaneously. Contact arrays (`contacts_*`) are grown by `realloc` in `addContacts`, one batch at a time.

### `GuardRingIdx`

```zig
pub const GuardRingIdx = enum(u32) {
    _,
    pub inline fn toInt(self: GuardRingIdx) u32
    pub inline fn fromInt(v: u32) GuardRingIdx
};
```

Opaque newtype over `u32`. Returned by `insert` and `insertWithStitchIn`. Used as an index into `GuardRingDB`.

---

## `GuardRingInserter`

### Fields

```zig
pub const GuardRingInserter = struct {
    db:           GuardRingDB,
    allocator:    std.mem.Allocator,
    pdk:          PdkConfig,          // copied by value
    drc:          ?*InlineDrcChecker, // optional, null = no DRC
    die_bbox:     Rect,
    num_warnings: u32,
};
```

### `init`

```zig
pub fn init(
    allocator: std.mem.Allocator,
    pdk:       *const PdkConfig,
    drc:       ?*InlineDrcChecker,
    die_bbox:  Rect,
) !GuardRingInserter
```

Creates `GuardRingDB.initCapacity(4)`. Copies `pdk` by value.

---

### `insert`

```zig
pub fn insert(
    self:      *GuardRingInserter,
    region:    Rect,
    ring_type: GuardRingType,
    net:       NetIdx,
) !GuardRingIdx
```

**Algorithm:**

1. Compute `outer` = region expanded by `gr_spacing + gr_width`.
2. Compute `inner` = region expanded by `gr_spacing`.
3. Validate: `(outer.x2 - outer.x1) - (inner.x2 - inner.x1) > 0` else return `error.RingTooNarrow`.
4. Clip `outer` to `die_bbox` via `clipRect`. Increment `num_warnings` if clipping occurred.
5. Determine contact pitch: use `pdk.via_spacing[0]` if > 0, else `gr_width + 0.14` (SKY130 licon fallback).
6. Append ring record to `db` with `has_stitch_in = false`.
7. Call `generateAndAddContacts(idx, pitch, clipped_outer, inner)`.
8. If DRC checker attached, call `registerWithDrc`.
9. Return `GuardRingIdx.fromInt(idx)`.

---

### `insertWithStitchIn`

```zig
pub fn insertWithStitchIn(
    self:           *GuardRingInserter,
    region:         Rect,
    ring_type:      GuardRingType,
    net:            NetIdx,
    existing_metal: []const Rect,
) !GuardRingIdx
```

Identical to `insert` except:
- Sets `has_stitch_in = true`.
- Calls `generateAndAddContactsWithStitchIn` instead of `generateAndAddContacts`.
- Contacts at positions that overlap any `existing_metal` rect are skipped.

This handles routing channels that cross the ring where pre-existing metal fills the ring width (e.g., a power bus that cuts through the ring side).

---

### `mergeDeepNWell`

```zig
pub fn mergeDeepNWell(
    self: *GuardRingInserter,
    a:    GuardRingIdx,
    b:    GuardRingIdx,
) !void
```

Merges two `deep_nwell` rings into one. Both must have the same `net`.

**Algorithm:**

1. Validate: both indices valid, both `ring_type == .deep_nwell`, same `net`. Otherwise return `error.InvalidRingIndex`, `error.NotDeepNWell`, or `error.RingNetConflict`.
2. Outer bbox merge: element-wise min/max (union):
   ```
   bbox_x1[a] = min(bbox_x1[a], bbox_x1[b])
   bbox_y1[a] = min(...)
   bbox_x2[a] = max(bbox_x2[a], bbox_x2[b])
   bbox_y2[a] = max(...)
   ```
3. Inner bbox merge: element-wise max/min (intersection):
   ```
   inner_x1[a] = max(inner_x1[a], inner_x1[b])
   inner_y1[a] = max(...)
   inner_x2[a] = min(inner_x2[a], inner_x2[b])
   inner_y2[a] = min(...)
   ```
4. Remove contacts for both rings (`removeContactsForRing(a)`, `removeContactsForRing(b)`).
5. Regenerate contacts for merged ring with current pitch.
6. Swap-remove ring `b` (last ring fills its slot; contact `ring_idx` references updated).

---

### `clipAllToDieEdge`

```zig
pub fn clipAllToDieEdge(self: *GuardRingInserter) void
```

Post-pass die-edge enforcement. For each ring, clamps `bbox_*` to `die_bbox` in-place. Then compact-filters contacts: any contact with `x` or `y` outside `die_bbox` is removed. This is a single-pass in-place compaction (dst/src pointer pattern).

---

### `generateAndAddContacts` (private)

```zig
fn generateAndAddContacts(
    self:     *GuardRingInserter,
    ring_idx: u32,
    pitch:    f32,
    outer:    Rect,
    inner:    Rect,
) !void
```

Places contacts at the **midline** of each of 4 ring bands:

| Band | Midline coordinate | Sweep range |
|---|---|---|
| Top | `top_y = (inner.y2 + outer.y2) * 0.5` | X from `outer.x1 + pitch*0.5` to `outer.x2 - pitch*0.25`, step `pitch` |
| Bottom | `bot_y = (outer.y1 + inner.y1) * 0.5` | Same X sweep |
| Left | `left_x = (outer.x1 + inner.x1) * 0.5` | Y from `inner.y1 + pitch*0.5` to `inner.y2 - pitch*0.25`, step `pitch` |
| Right | `right_x = (inner.x2 + outer.x2) * 0.5` | Same Y sweep |

Top and bottom cover the full outer width. Left and right skip corners (range uses `inner.y1`/`inner.y2`, not `outer`). Contacts accumulated in `ArrayListUnmanaged(f32)` then batch-added via `db.addContacts`.

---

### `generateAndAddContactsWithStitchIn` (private)

Same as `generateAndAddContacts` but wraps each position check in:

```zig
if (!pointOverlapsAny(x, y, existing_metal)) {
    // append contact
}
```

`pointOverlapsAny` is an O(n) linear scan over `existing_metal` rects using inclusive containment: `x >= r.x1 and x <= r.x2 and y >= r.y1 and y <= r.y2`.

---

### `registerWithDrc` (private)

```zig
fn registerWithDrc(
    self:  *GuardRingInserter,
    drc:   *InlineDrcChecker,
    outer: Rect,
    inner: Rect,
    net:   NetIdx,
) !void
```

Registers 4 ring-band segments with the DRC checker (one per side), all on layer 0, width = `pdk.guard_ring_width`. This allows subsequent routing to avoid spacing violations against the ring.

---

### Accessor Functions

| Function | Return | Description |
|---|---|---|
| `getRing(i)` | `GuardRing` | AoS record for ring `i` |
| `ringCount()` | `u32` | Total rings inserted |
| `contactCount(ring_idx)` | `u32` | Contacts belonging to a specific ring (O(n) scan) |
| `totalContactCount()` | `u32` | Sum of all contacts |

---

### `GuardRingDB.swapRemove` (private)

Swap-removes ring at `idx` with the last ring. Updates `contacts_ring_idx` entries that pointed to `last` to now point to `idx`. Decrements `len`. Does not free memory (capacity preserved for reuse).

---

## Shield Routing

### Purpose

A **shield wire** is a metal wire routed adjacent to a sensitive signal line, connected to a stable reference (usually VSS). The shield intercepts electrostatic coupling from aggressors, presenting a low-impedance path to ground rather than allowing noise to inject into the signal.

Two modes:

| Mode | `shield_net` | `is_driven` | Use case |
|---|---|---|---|
| `routeShielded` | `ground_net` | `false` | Standard shielding for sensitive analog nets |
| `routeDrivenGuard` | `signal_net` (same) | `true` | High-impedance nodes (e.g., op-amp input); bootstrap guard eliminates leakage |

### SVG Diagram — Shielded Routing and Via Drops

```svg
<svg xmlns="http://www.w3.org/2000/svg" width="720" height="480" viewBox="0 0 720 480">
  <style>
    text { font-family: 'Inter', 'Segoe UI', sans-serif; font-size: 12px; fill: #B0BEC5; }
    .label-sm    { font-size: 10px; fill: #78909C; }
    .label-acc   { fill: #00C4E8; }
    .label-grn   { fill: #43A047; }
    .label-red   { fill: #EF5350; }
    .label-blu   { fill: #1E88E5; }
    .label-title { font-size: 15px; font-weight: 600; fill: #E0E0E0; }
    .label-org   { fill: #FF9800; }
  </style>

  <!-- Background -->
  <rect width="720" height="480" fill="#060C18" rx="10"/>

  <!-- Title -->
  <text x="360" y="30" text-anchor="middle" class="label-title">Shield Routing — Signal Wire with VSS Shield on Adjacent Layer</text>

  <!-- ─── Main plan view ─── -->

  <!-- Layer indicator labels -->
  <text x="40" y="130" class="label-blu">Met1 (signal)</text>
  <text x="40" y="265" class="label-red">Met2 (shield)</text>

  <!-- Signal wire (Met1) -->
  <rect x="120" y="110" width="480" height="30" rx="4" fill="#1565C0" stroke="#1E88E5" stroke-width="1.5"/>
  <text x="360" y="130" text-anchor="middle" fill="white" font-size="11" font-family="'Inter','Segoe UI',sans-serif">SIGNAL (Met1, net A)</text>

  <!-- Spacing annotation -->
  <line x1="360" y1="140" x2="360" y2="240" stroke="#00C4E8" stroke-width="1" stroke-dasharray="4 3"/>
  <text x="366" y="200" class="label-acc" font-size="10">min_spacing</text>
  <text x="366" y="214" class="label-acc" font-size="10">(expansion)</text>

  <!-- Shield wire (Met2) — expanded by min_spacing on each side -->
  <rect x="100" y="240" width="520" height="40" rx="4" fill="#4A0000" stroke="#EF5350" stroke-width="1.5"/>
  <text x="360" y="265" text-anchor="middle" fill="#EF5350" font-size="11" font-family="'Inter','Segoe UI',sans-serif">VSS SHIELD (Met2, net VSS, is_driven=false)</text>

  <!-- Expansion arrows (left / right) -->
  <line x1="120" y1="285" x2="100" y2="285" stroke="#EF5350" stroke-width="1"/>
  <text x="65" y="289" class="label-red" font-size="10">+exp</text>
  <line x1="600" y1="285" x2="620" y2="285" stroke="#EF5350" stroke-width="1"/>
  <text x="626" y="289" class="label-red" font-size="10">+exp</text>

  <!-- Via drops (circles at left and right of shield) -->
  <circle cx="130" cy="262" r="10" fill="none" stroke="#43A047" stroke-width="2"/>
  <text x="118" y="266" fill="#43A047" font-size="10">V</text>
  <circle cx="590" cy="262" r="10" fill="none" stroke="#43A047" stroke-width="2"/>
  <text x="578" y="266" fill="#43A047" font-size="10">V</text>

  <!-- Via drop labels -->
  <text x="95" y="310" class="label-grn" font-size="11">Via: Met2→VSS rail</text>
  <text x="553" y="310" class="label-grn" font-size="11">Via: Met2→VSS rail</text>

  <!-- enc annotation (left via inward offset) -->
  <line x1="100" y1="308" x2="130" y2="308" stroke="#43A047" stroke-width="1"/>
  <text x="108" y="322" class="label-grn" font-size="9">enc</text>

  <!-- ─── Cross-section inset ─── -->
  <rect x="100" y="345" width="520" height="100" rx="6" fill="#0A111F" stroke="#1E3A5C" stroke-width="1"/>
  <text x="360" y="365" text-anchor="middle" fill="#78909C" font-size="11" font-family="'Inter','Segoe UI',sans-serif">Cross-section view (not to scale)</text>

  <!-- Substrate -->
  <rect x="120" y="415" width="480" height="18" fill="#2E1B00" stroke="#8D6E63" stroke-width="1"/>
  <text x="360" y="429" text-anchor="middle" fill="#8D6E63" font-size="10" font-family="'Inter','Segoe UI',sans-serif">P-substrate</text>

  <!-- Metal layers cross-section -->
  <!-- Met1 (signal) -->
  <rect x="200" y="390" width="100" height="14" fill="#1565C0" stroke="#1E88E5" stroke-width="1"/>
  <text x="250" y="402" text-anchor="middle" fill="white" font-size="9" font-family="'Inter','Segoe UI',sans-serif">Met1</text>

  <!-- Via -->
  <rect x="310" y="390" width="8" height="14" fill="#43A047" stroke="#43A047"/>

  <!-- Met2 (shield) -->
  <rect x="150" y="374" width="350" height="14" fill="#4A0000" stroke="#EF5350" stroke-width="1"/>
  <text x="325" y="386" text-anchor="middle" fill="#EF5350" font-size="9" font-family="'Inter','Segoe UI',sans-serif">Met2 shield (VSS)</text>

  <!-- Legend -->
  <rect x="540" y="345" width="160" height="90" rx="4" fill="#0D1A2E" stroke="#1E3A5C" stroke-width="1"/>
  <rect x="552" y="358" width="16" height="10" fill="#1565C0" stroke="#1E88E5"/>
  <text x="575" y="368">Signal Met1</text>
  <rect x="552" y="376" width="16" height="10" fill="#4A0000" stroke="#EF5350"/>
  <text x="575" y="386">VSS Shield Met2</text>
  <circle cx="560" cy="403" r="5" fill="none" stroke="#43A047" stroke-width="1.5"/>
  <text x="575" y="407">Via drop</text>
  <line x1="552" y1="421" x2="568" y2="421" stroke="#00C4E8" stroke-width="1" stroke-dasharray="4 2"/>
  <text x="575" y="425">Spacing</text>
</svg>
```

---

## Data Structures

### `ShieldWire` (AoS record)

```zig
pub const ShieldWire = struct {
    x1, y1, x2, y2: f32,   // bounding rect of shield segment
    width:           f32,   // >= pdk.min_width[layer]
    layer:           u8,    // = adjacentLayer(signal_layer)
    shield_net:      NetIdx, // VSS for grounded; signal_net for driven guard
    signal_net:      NetIdx, // the net being shielded
    is_driven:       bool,   // false = grounded, true = driven guard
};
```

### `ShieldDB` (SoA table)

9 columns: `x1`, `y1`, `x2`, `y2`, `width`, `layer`, `shield_net`, `signal_net`, `is_driven`.

Growth strategy: `grow(capacity*2 + 4)`. First allocation from zero (zero capacity) branches to fresh `alloc`; subsequent growths use `realloc`.

Key methods:
- `init(allocator)` — zero capacity
- `initCapacity(allocator, n)` — pre-allocate n slots
- `append(wire)` — amortized O(1)
- `getWire(i)` — AoS accessor, O(1)
- `deinit` — frees all 9 arrays if capacity > 0

### `ViaDrop` (AoS record)

```zig
pub const ViaDrop = struct {
    x, y:        f32,    // via center
    via_width:   f32,    // pdk.via_width[shield_layer]
    from_layer:  u8,     // shield layer
    to_layer:    u8,     // signal layer (shield_layer - 1, clamped to 0)
    net:         NetIdx, // shield_net of parent shield
    shield_idx:  u32,    // index into ShieldDB
};
```

### `ViaDropDB` (SoA table)

7 columns: `x`, `y`, `via_width`, `from_layer`, `to_layer`, `net`, `shield_idx`.

Same growth pattern as `ShieldDB`. Key methods: `append`, `getViaDrop`, `deinit`.

### `ValidationResult`

```zig
pub const ValidationResult = struct {
    spacing_violations:   u32 = 0,
    width_violations:     u32 = 0,
    enclosure_violations: u32 = 0,
    total_checked:        u32 = 0,

    pub fn isClean(self: ValidationResult) bool   // all violation counts == 0
    pub fn totalViolations(self: ValidationResult) u32  // sum of all three
};
```

---

## `ShieldRouter`

### Fields

```zig
pub const ShieldRouter = struct {
    db:        ShieldDB,
    via_db:    ViaDropDB,
    allocator: std.mem.Allocator,
    pdk:       PdkConfig,            // copied by value
    drc:       ?*InlineDrcChecker,   // null = no conflict checking
};
```

### `init`

```zig
pub fn init(allocator: std.mem.Allocator, pdk: *const PdkConfig) !ShieldRouter
```

Initializes both `db` and `via_db` with zero capacity.

### `setDrcChecker`

```zig
pub fn setDrcChecker(self: *ShieldRouter, drc: *InlineDrcChecker) void
```

Attaches a DRC checker. Once attached, `routeShielded` and `routeDrivenGuard` will query it before accepting each shield segment.

---

### `routeShielded`

```zig
pub fn routeShielded(
    self:            *ShieldRouter,
    signal_segments: []const SignalSegment,
    ground_net:      NetIdx,
    signal_layer:    u8,
) !void
```

**Algorithm (per segment):**

1. `shield_layer = (signal_layer + 1) % num_metal_layers`
2. `via_pitch = pdk.via_spacing[shield_layer]` (fallback: `via_width`, then `min_width`)
3. Skip segment if `seg.length() < via_pitch * 2` (too short to place both endpoint vias)
4. Compute shield rect: `sx1 = seg.x1 - exp`, `sy1 = seg.y1 - exp`, `sx2 = seg.x2 + exp`, `sy2 = seg.y2 + exp` where `exp = pdk.min_spacing[shield_layer]`
5. `shield_w = max(seg.width, pdk.min_width[shield_layer])`
6. DRC check (3 points: start, end, midpoint) against `ground_net` on `shield_layer`. If any returns `hard_violation = true`, skip.
7. `db.append` with `shield_net = ground_net`, `is_driven = false`
8. Register shield with DRC checker (so future shields/routes see it as obstacle)

---

### `routeDrivenGuard`

```zig
pub fn routeDrivenGuard(
    self:            *ShieldRouter,
    signal_segments: []const SignalSegment,
    guard_net:       NetIdx,
    shield_layer:    u8,
) !void
```

Identical structure to `routeShielded` except:
- The caller provides `shield_layer` directly (not derived from `signal_layer + 1`)
- DRC check uses `seg.net` (signal net) instead of `ground_net`
- `shield_net = guard_net` (which equals `signal_net` at call site)
- `is_driven = true`

Used for bootstrap guard topology where the shield is driven at signal potential to eliminate leakage current.

---

### `generateViaDrops`

```zig
pub fn generateViaDrops(self: *ShieldRouter, signal_layer: u8) !void
```

Iterates over all shields in `db`. For each shield:

1. `shield_layer = db.layer[i]`
2. `vw = pdk.via_width[shield_layer]`
3. `enc = pdk.min_enclosure[shield_layer]`
4. Two via positions, both at midline Y = `(y1 + y2) * 0.5`:
   - Near start: `x = x1 + enc + vw*0.5`
   - Near end: `x = x2 - enc - vw*0.5`
5. `via_to_signal = shield_layer - 1` (clamped to 0)
6. For each via: DRC check on `shield_layer` at via position. Skip on `hard_violation`.
7. `via_db.append` with `from_layer = shield_layer`, `to_layer = via_to_signal`, `shield_idx = i`

The `signal_layer` parameter is unused (computed from the stored shield layer).

---

### `registerShieldsWithDrc`

```zig
pub fn registerShieldsWithDrc(self: *const ShieldRouter, drc: *InlineDrcChecker) !void
```

Post-routing bulk registration for workflows where shields were routed without an attached DRC checker. Iterates all shields and calls `drc.addSegment` for each. Useful when shields are built in batch and DRC is attached later.

---

### `validateShields`

```zig
pub fn validateShields(self: *const ShieldRouter) ValidationResult
```

Three-pass validation:

**Pass 1 — Width check:**
For each shield: `db.width[i] < pdk.min_width[db.layer[i]]` → increment `width_violations`.

**Pass 2 — Spacing check (via DRC checker):**
For each shield: query DRC checker at midpoint `((x1+x2)/2, (y1+y2)/2)` with `shield_net`. `hard_violation` → increment `spacing_violations`.

**Pass 3 — Via enclosure check:**
For each via drop: compute enclosure on all 4 sides of the via bounding box within the parent shield bounding box. If any side < `pdk.min_enclosure[shield_layer]` → increment `enclosure_violations`.

```
enc_left   = via.x - vhw - shield.x1
enc_right  = shield.x2 - (via.x + vhw)
enc_bottom = via.y - vhw - shield.y1
enc_top    = shield.y2 - (via.y + vhw)
```

---

### Accessor Functions

| Function | Return | Description |
|---|---|---|
| `getShield(i)` | `ShieldWire` | AoS accessor for shield wire |
| `shieldCount()` | `u32` | Number of shield wires |
| `viaDropCount()` | `u32` | Number of via drops |

---

## Helper Functions

### `adjacentLayer`

```zig
fn adjacentLayer(layer: u8, num_metal: u8) u8
    return (layer + 1) % num_metal
```

Computes the shield layer with wrap-around. Layer 4 in a 5-metal stack → layer 0.

### `viaPitch`

```zig
fn viaPitch(pdk: *const PdkConfig, layer: u8) f32
```

Priority chain:
1. `pdk.via_spacing[layer]` if > 0
2. `pdk.via_width[layer]` if > 0
3. `pdk.min_width[layer]` (conservative fallback)

Guarantees non-zero result for all valid PDK configurations.

### `SignalSegment` (input type)

```zig
pub const SignalSegment = struct {
    x1, y1, x2, y2: f32,
    width:           f32,
    net:             NetIdx,

    pub fn length(self: SignalSegment) f32  // Manhattan: |x2-x1| + |y2-y1|
};
```

Input-only struct. Caller constructs from routed signal segments before calling `routeShielded` or `routeDrivenGuard`.

---

## Guard Ring Test Coverage

| Test | Validates |
|---|---|
| `GuardRingDB initCapacity and append` | SoA field storage, `getRing` round-trip, `ring_type` and `net` |
| `GuardRingDB grows capacity` | 5 rings from capacity 2, auto-grow to ≥ 5 |
| `GuardRingDB addContacts and count` | Batch contact add, `contacts_x`, `contacts_ring_idx` |
| `GuardRingInserter.insert forms complete enclosure` | Outer encloses region, inner encloses region, contacts exist |
| `GuardRingInserter contact count matches perimeter/pitch` | Count within 50% of `perimeter / pitch` |
| `GuardRingInserter die edge clipping` | Ring near origin clips to die, `num_warnings > 0` |
| `GuardRingInserter clipAllToDieEdge removes out-of-bounds contacts` | After shrinking die, contact count ≤ before |
| `GuardRingInserter.mergeDeepNWell` | Merged outer covers both regions, `ringCount() == 1` |
| `GuardRingInserter merge rejects different nets` | Returns `error.RingNetConflict` |
| `GuardRingInserter insertWithStitchIn sets has_stitch_in=true` | Flag set |
| `GuardRingInserter insertWithStitchIn skips overlapping contacts` | Fewer contacts than normal insert |
| `GuardRingIdx round-trip` | `fromInt(99).toInt() == 99` |
| `GuardRingType enum values` | Explicit u8 values 0–3 |
| `pointOverlapsAny detects point in rect` | True/false for contained/uncontained points |

## Shield Router Test Coverage

| Test | Validates |
|---|---|
| `ShieldDB append and getWire round-trip` | All 9 fields stored and retrieved |
| `ShieldDB grows capacity correctly` | 5 inserts from capacity 2 |
| `ShieldDB init with zero capacity then append` | First-allocation branch from capacity 0 |
| `adjacentLayer wraps correctly` | Layers 0→1, 1→2, 4→0 |
| `SignalSegment.length is Manhattan distance` | `(3,4)` = 7 |
| `ShieldRouter.init and deinit` | Zero counts after init |
| `ShieldRouter routeShielded skips short segments` | 0 shields for sub-`2*via_pitch` segment |
| `ShieldRouter routeShielded creates shield wires around signal` | Layer, expansion, width, `is_driven`, `shield_net` |
| `ShieldRouter routeDrivenGuard sets is_driven=true` | Flag and `shield_net == signal_net` |
| `ShieldRouter routeShielded sets is_driven=false` | Flag false |
| `ShieldRouter shield layer is adjacent to signal layer` | Signal layer 1 → shield layer 2 |
| `ShieldRouter DRC conflict causes shield to be skipped` | Obstacle on shield layer → 0 shields |
| `ShieldRouter generates via drops at shield endpoints` | 2 vias, correct layers, `via0.x < via1.x` |
| `ShieldRouter registerShieldsWithDrc populates checker` | DRC segment count 0→1 |
| `ShieldRouter validateShields passes for clean placement` | `width_violations == 0` |
| `ShieldRouter validateShields detects width violation` | `width_violations > 0` for width 0.01 |
| `ShieldRouter multiple segments routed` | 2 shields same layer, different signal nets |
| `ShieldRouter DRC registration prevents self-conflict` | After routing, `drc.segments.len == 1` |
| `ViaDropDB append and getViaDrop round-trip` | All 7 fields |
| `ValidationResult helpers` | `isClean`, `totalViolations` |
