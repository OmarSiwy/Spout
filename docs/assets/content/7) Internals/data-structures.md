# Core Data Structures

> **Source files:** `src/core/device_arrays.zig`, `src/core/route_arrays.zig`, `src/lib.zig`, `src/router/pex_feedback.zig`, `src/router/lde.zig`

---

## 1. Design Philosophy: Structure of Arrays (SoA)

Spout uses **Structure of Arrays** (SoA) instead of Array of Structures (AoS) throughout its core data model. This has significant consequences:

**AoS (traditional C struct):**
```c
struct Device { float w; float l; int type; float pos[2]; };
struct Device devices[N];  // Array of structs
```

**SoA (Spout's approach):**
```zig
struct DeviceArrays {
    types: []DeviceType,      // All types in one array
    params: []DeviceParams,   // All params in one array
    positions: [][2]f32,      // All positions in one array
    // ...
}
```

**Why SoA?**
1. **SIMD vectorization:** Processing all widths across all devices (`params[i].w` for all i) can be vectorized by the CPU — all the width values are contiguous in memory.
2. **Cache efficiency for partial operations:** Updating only positions (during SA perturbation) loads only the position array into cache, not the whole device record.
3. **FFI friendliness:** C-ABI consumers can receive raw float pointers (`float* widths, float* lengths`) without structure layout concerns.
4. **Parallel computation:** Planners/routers that operate on subsets of fields (e.g., only position and dimension for placement, only net and layer for routing) access only the relevant arrays.

---

## 2. `DeviceArrays` — Per-Device Properties

**File:** `src/core/device_arrays.zig`

```zig
pub const DeviceArrays = struct {
    types:         []DeviceType,     // What kind of device (NMOS, PMOS, res, cap, ...)
    params:        []DeviceParams,   // W, L, fingers, mult, value
    positions:     [][2]f32,         // [x, y] placement position in µm
    dimensions:    [][2]f32,         // [width, height] physical bounding box in µm
    embeddings:    [][64]f32,        // 64-dim learned embedding vector (ML feature)
    predicted_cap: []f32,            // ML-predicted coupling capacitance (fF)
    orientations:  []Orientation,    // N/S/E/W/FN/FS/FE/FW
    is_dummy:      []bool,           // True if this is a non-functional dummy device
    allocator:     std.mem.Allocator,
    len:           u32,
};
```

### 2.1 Field Details

#### `types: []DeviceType`
Enum identifying device category. Used by:
- `computeDeviceDimensions` — selects the geometry computation formula
- GDSII exporter — selects which layer shapes to draw
- SA placer cost function — applies device-type-specific constraints
- LDE router — determines SA/SB orientation (NMOS left=source, PMOS right=source)

#### `params: []DeviceParams`
```zig
pub const DeviceParams = struct {
    w:       f32,   // Channel width (SPICE meters, ×1e6 → µm)
    l:       f32,   // Channel length (SPICE meters, ×1e6 → µm)
    fingers: u16,   // Number of gate fingers
    mult:    u16,   // Multiplicity (parallel identical devices)
    value:   f32,   // R (Ω) or C (F) or L (H) for passive devices
};
```

Zero-initialized on `DeviceArrays.init()`. The SPICE parser populates these from element lines.

#### `positions: [][2]f32`
Current placement position `[x, y]` in micrometers. Updated by the SA placer at each accepted move. The GDSII exporter uses this to determine where to draw each device.

#### `dimensions: [][2]f32`
Physical bounding box `[width, height]` computed by `computeDeviceDimensions` in `src/lib.zig`. This includes:
- The device's active area
- Poly extension beyond active
- Implant/nwell enclosure
- Body tap region
- Guard ring margin

These dimensions are what the SA placer uses for overlap penalty computation — if two devices' bounding boxes overlap, there is a large overlap cost.

#### `embeddings: [][64]f32`
64-dimensional float vector, one per device. Populated by the ML embedding model (if enabled). Used by the SA placer's `w_embed_similarity` cost term — devices with similar embeddings are nudged toward proximity in the placed layout.

#### `predicted_cap: []f32`
ML model's predicted coupling capacitance for each device in femtofarads. Used by the SA placer's `w_parasitic` cost term — devices with high predicted coupling are placed farther apart.

#### `orientations: []Orientation`
Device orientation (rotation/mirror). The SA placer can perturb orientation as well as position. Default is `.N` (no rotation).

#### `is_dummy: []bool`
Marks devices as non-functional dummies. Dummies are:
- Included in the placed layout for density/symmetry
- Excluded from the LVS check
- Excluded from the schematic's SPICE model

### 2.2 Memory Ownership

`DeviceArrays.init(allocator, count)` allocates all arrays with the given count and zero-initializes. The `allocator` is stored in the struct and used by `deinit()` to free all arrays. The `SpoutContext` (in `src/lib.zig`) owns one `DeviceArrays` for the duration of the context's lifetime.

**Invariant:** All arrays in `DeviceArrays` are always the same length (`len`). Accessing index `i` is safe for any `i < len` on any field.

---

## 3. `RouteArrays` — Per-Segment Routing Data

**File:** `src/core/route_arrays.zig`

```zig
pub const RouteArrays = struct {
    layer:    []u8,                  // Routing layer index (0=LI, 1=M1, ..., 5=M5)
    x1:       []f32,                 // Segment start X (µm, centerline)
    y1:       []f32,                 // Segment start Y (µm, centerline)
    x2:       []f32,                 // Segment end X (µm, centerline)
    y2:       []f32,                 // Segment end Y (µm, centerline)
    width:    []f32,                 // Segment width (µm)
    net:      []NetIdx,              // Which net this segment belongs to
    flags:    []RouteSegmentFlags,   // is_shield, is_dummy_via, is_jog
    allocator: std.mem.Allocator,
    len:      u32,
    capacity: u32,                   // Allocated capacity (may exceed len)
};
```

### 3.1 Layer Index Convention

```
Index 0 → LI  (GDS 67/20)
Index 1 → M1  (GDS 68/20)
Index 2 → M2  (GDS 69/20)
Index 3 → M3  (GDS 70/20)
Index 4 → M4  (GDS 71/20)
Index 5 → M5  (GDS 72/20)
```

When indexing into PDK config arrays (0-indexed from M1), use `route_layer - 1` for metal layers. For LI (route layer 0), use `li_*` fields.

### 3.2 Segment Geometry

Segments are stored as axis-aligned centerlines:
- `(x1, y1)` → `(x2, y2)` is the centerline
- The physical wire rectangle is `[x1-w/2, y1-w/2, x2+w/2, y2+w/2]` (expanded by half-width)
- For horizontal segments: `y1 == y2`, `x1 < x2`
- For vertical segments: `x1 == x2`, `y1 < y2`
- For via segments (zero-length): `x1 == x2 && y1 == y2`

### 3.3 Via Representation

Vias in `RouteArrays` are encoded as **zero-length segments**:
- `x1 == x2 && y1 == y2` identifies a via
- The `layer` field indicates which cut layer the via is on
- `pex_feedback.zig` counts these for via-count matching:
  ```zig
  if (filtered.x1[i] == filtered.x2[i] and filtered.y1[i] == filtered.y2[i]) {
      via_count += 1;
  }
  ```

### 3.4 Segment Flags

```zig
pub const RouteSegmentFlags = packed struct(u8) {
    is_shield:    bool = false,   // This segment is a shielding wire
    is_dummy_via: bool = false,   // Dummy via inserted for parasitic matching
    is_jog:       bool = false,   // Jog segment inserted for length matching
    _padding:     u5 = 0,
};
```

These flags are used by:
- GDSII exporter — may render shields differently (same geometry, different label)
- PEX feedback — dummy vias do not carry signal but do contribute resistance
- Reporting — jog segments are excluded from the routing length statistics for LVS

### 3.5 Dynamic Growth

`RouteArrays` starts with capacity `count` but can grow dynamically via `append()`:

```
Initial capacity → count (may be 0)
First append from capacity 0 → grows to 16
Subsequent appends when full → capacity × 2 (doubling strategy)
```

Growth: `growTo(new_cap)` calls `realloc` on all arrays simultaneously. All arrays grow together.

**Thread safety:** `RouteArrays` is not thread-safe. The router uses it single-threaded during search, but the PEX feedback loop also mutates it (width scaling, jog insertion, dummy via insertion).

### 3.6 FFI Serialization

For Python FFI access, `SpoutContext` maintains a `route_segments_flat: ?[]f32` — a flattened buffer of 7 floats per segment (layer_as_float, x1, y1, x2, y2, width, net_id). This is rebuilt on demand and freed when the context is destroyed.

---

## 4. `SpoutContext` — Top-Level Handle

**File:** `src/lib.zig`

```zig
const SpoutContext = struct {
    devices:    device_arrays.DeviceArrays,
    nets:       net_arrays.NetArrays,
    pins:       pin_edge_arrays.PinEdgeArrays,
    constraints: constraint_arrays.ConstraintArrays,
    routes:     ?route_arrays.RouteArrays,     // null until routing completes
    adj:        ?adjacency.FlatAdjList,         // null until constraints extracted
    pdk:        layout_if.PdkConfig,
    allocator:  std.mem.Allocator,
    initialized: bool,

    route_segments_flat: ?[]f32,               // FFI cache
    parse_result:        ?parser.ParseResult,  // Kept alive for lifetime of context
    macro_result:        ?macro_mod.MacroResult,
    template_result:     ?template_mod.TemplateResult,
};
```

**Ownership model:**
- `SpoutContext` is allocated on the heap by `spout_init_layout()` and freed by `spout_destroy()`.
- All sub-structs are owned by `SpoutContext` and freed on destroy.
- `routes` is `?RouteArrays` — null until `spout_run_routing()` is called.
- `adj` is `?FlatAdjList` — null until `spout_extract_constraints()` is called.

**C-ABI exposure:**
```c
void* spout_init_layout(uint8_t backend, uint8_t pdk_id);
void  spout_destroy(void* handle);
int   spout_parse_netlist(void* handle, const char* path, size_t len);
int   spout_extract_constraints(void* handle);
int   spout_run_sa_placement(void* handle, const void* config, size_t len);
int   spout_run_routing(void* handle);
int   spout_export_gdsii_named(void* handle, const char* path, size_t, const char* cell, size_t);
```

Return values: 0 = success, non-zero = error.

---

## 5. `LDEConstraintDB` — Local Density Effect Constraints

**File:** `src/router/lde.zig`

```zig
pub const LDEConstraintDB = struct {
    allocator:  std.mem.Allocator,
    device:     std.ArrayListUnmanaged(DeviceIdx),
    min_sa:     std.ArrayListUnmanaged(f32),   // Min source-to-active-edge spacing (µm)
    max_sa:     std.ArrayListUnmanaged(f32),   // Max source-to-active-edge spacing (µm)
    min_sb:     std.ArrayListUnmanaged(f32),   // Min body-to-active-edge spacing (µm)
    max_sb:     std.ArrayListUnmanaged(f32),   // Max body-to-active-edge spacing (µm)
    sc_target:  std.ArrayListUnmanaged(f32),   // SCA target: active-to-well-edge distance (µm)
};
```

**Per-entry semantics (one entry per device with LDE constraint):**
- `device`: Which device this constraint applies to (by `DeviceIdx`)
- `min_sa` / `max_sa`: SA = Source-to-Active-edge spacing. Controls proximity of neighboring active regions on the source side.
- `min_sb` / `max_sb`: SB = Body-to-Active-edge spacing. Controls proximity on the body (well) side.
- `sc_target`: SCA = Active-to-Well-edge distance for WPE (Well Proximity Effect) compensation.

**Direction convention:**
- NMOS: left side = source (SA), right side = body (SB)
- PMOS: right side = source (SA), left side = body (SB)

**Used by:**
- `generateKeepouts()` — produces routing exclusion zones around devices to prevent wire routing from altering SA/SB distances
- `generateWPEKeepouts()` — produces exclusion zones for well edges to maintain SCA
- `computeLDECost()` / `computeLDECostScaled()` — A\* cost function penalties for SA/SB asymmetry between matched devices

---

## 6. `MatchReportDB` — PEX Analog Matching Reports

**File:** `src/router/pex_feedback.zig`

```zig
pub const MatchReportDB = struct {
    group_idx:      std.ArrayListUnmanaged(AnalogGroupIdx),
    passes:         std.ArrayListUnmanaged(bool),
    r_ratio:        std.ArrayListUnmanaged(f32),   // |R_a-R_b|/max(R_a,R_b) ∈ [0,1]
    c_ratio:        std.ArrayListUnmanaged(f32),   // |C_a-C_b|/max(C_a,C_b) ∈ [0,1]
    length_ratio:   std.ArrayListUnmanaged(f32),   // |L_a-L_b|/max(L_a,L_b) ∈ [0,1]
    via_delta:      std.ArrayListUnmanaged(i32),   // via_count_a - via_count_b
    coupling_delta: std.ArrayListUnmanaged(f32),   // |C_a-C_b| in fF
    failure_reason: std.ArrayListUnmanaged(u8),    // FailureReason enum stored as u8
    allocator:      std.mem.Allocator,
};
```

One entry per matched group per PEX feedback iteration. Stored as SoA — all `r_ratio` values for all groups in one array, etc. This allows bulk analysis (e.g., "find all groups where r_ratio > 0.1") using SIMD comparisons.

---

## 7. `Rect` Geometry Type

**File:** `src/router/lde.zig`

```zig
pub const Rect = struct {
    x1: f32, y1: f32,  // Bottom-left corner (min x, min y)
    x2: f32, y2: f32,  // Top-right corner (max x, max y)

    pub fn width(self) f32        { return self.x2 - self.x1; }
    pub fn height(self) f32       { return self.y2 - self.y1; }
    pub fn centerX(self) f32      { return (self.x1 + self.x2) * 0.5; }
    pub fn centerY(self) f32      { return (self.y1 + self.y2) * 0.5; }
    pub fn overlaps(self, other)  { /* AABB test */ }
    pub fn expand(self, amount)   { /* symmetric */ }
    pub fn expandAsymmetric(self, left, right, bottom, top) { /* per-side */ }
};
```

Used throughout the router for device bounding boxes, keepout regions, and spatial queries. `overlaps` tests: `x1 < other.x2 AND x2 > other.x1 AND y1 < other.y2 AND y2 > other.y1`.

---

## 8. Index Types

Spout uses strongly-typed newtype indices to prevent accidental mixing of device/net/group indices:

```zig
// core/types.zig
pub const DeviceIdx = enum(u32) { _, pub fn toInt(...); pub fn fromInt(...) };
pub const NetIdx    = enum(u32) { _, pub fn toInt(...); pub fn fromInt(...) };

// pex_feedback.zig
pub const AnalogGroupIdx = enum(u32) { _, pub fn toInt(...); pub fn fromInt(...) };
```

These are Zig `enum(u32)` types — they have the same ABI as `u32` but are type-incompatible at compile time. Passing a `NetIdx` where a `DeviceIdx` is expected is a compile error, not a runtime bug.

The `_` is a placeholder used in Zig to make the enum anonymous at the value level — the actual integer values are uninterpreted indices.

---

## 9. Interface Between `DeviceArrays` and `RouteArrays`

The two arrays are linked through `NetIdx`:

```
DeviceArrays.params[device_i] → DeviceParams (W, L, fingers)
    ↓ (via pin extraction)
PinEdgeArrays → {device: DeviceIdx, terminal: TerminalType, net: NetIdx}
    ↓ (via routing)
RouteArrays.net[seg_j] == NetIdx → segments connect device terminals
```

The placer operates on `DeviceArrays.positions` and `DeviceArrays.dimensions`.
The router takes pin positions (from `PinEdgeArrays`) and produces `RouteArrays`.
PEX operates on `RouteArrays` to compute parasitics per net.
The GDSII exporter reads both `DeviceArrays` (for device geometry) and `RouteArrays` (for wire geometry).

---

## 10. Memory Allocation Strategy

Spout uses Zig's allocator interface throughout:
- All allocations are explicit — no hidden heap use.
- The `SpoutContext` is created with an arena allocator (from `src/lib.zig`'s `spout_init_layout`), so all sub-allocations can be freed together on destroy.
- `DeviceArrays` and `RouteArrays` store their allocator and call `free` individually in `deinit()`.
- `std.ArrayListUnmanaged` (used in `LDEConstraintDB`, `MatchReportDB`) requires the caller to pass the allocator on every operation — the allocator is stored separately in the DB struct.

**`errdefer` pattern:** All `init` functions use `errdefer allocator.free(...)` for each sub-allocation so that partial failures during init do not leak memory.
