# Python FFI Documentation

Complete documentation of Spout's Python-to-Zig interface, covering the native CPython extension architecture, every exported function, memory management, and working usage examples.

---

## Architecture Overview

<svg viewBox="0 0 1100 540" xmlns="http://www.w3.org/2000/svg" font-family="'Inter', 'Segoe UI', sans-serif">
  <!-- Background -->
  <rect width="1100" height="540" fill="#060C18"/>
  <text x="550" y="34" fill="#B8D0E8" font-size="17" font-weight="700" text-anchor="middle">Spout FFI Architecture: Python ↔ Zig via C ABI</text>

  <!-- Python Side (left) -->
  <rect x="20" y="55" width="310" height="460" rx="8" fill="#0A1825" stroke="#14263E" stroke-width="1.5"/>
  <text x="175" y="80" fill="#1E88E5" font-size="14" font-weight="700" text-anchor="middle">Python Layer</text>
  <text x="175" y="98" fill="#3E5E80" font-size="11" text-anchor="middle">python/</text>

  <!-- Python code boxes -->
  <rect x="38" y="110" width="276" height="42" rx="4" fill="#0D1E36" stroke="#14263E"/>
  <text x="176" y="128" fill="#B8D0E8" font-size="12" text-anchor="middle">import spout</text>
  <text x="176" y="144" fill="#3E5E80" font-size="11" text-anchor="middle">from python/__init__.py (public API)</text>

  <rect x="38" y="162" width="276" height="54" rx="4" fill="#0D1E36" stroke="#14263E"/>
  <text x="176" y="180" fill="#B8D0E8" font-size="12" text-anchor="middle">layout = spout.Layout(backend, pdk_id)</text>
  <text x="176" y="196" fill="#3E5E80" font-size="11" text-anchor="middle">PyOZ-wrapped Zig struct</text>
  <text x="176" y="210" fill="#3E5E80" font-size="11" text-anchor="middle">__new__ calls spout_init_layout()</text>

  <rect x="38" y="226" width="276" height="42" rx="4" fill="#0D1E36" stroke="#14263E"/>
  <text x="176" y="244" fill="#B8D0E8" font-size="12" text-anchor="middle">layout.parse_netlist(path)</text>
  <text x="176" y="259" fill="#3E5E80" font-size="11" text-anchor="middle">str → const u8 slice</text>

  <rect x="38" y="278" width="276" height="42" rx="4" fill="#0D1E36" stroke="#14263E"/>
  <text x="176" y="296" fill="#B8D0E8" font-size="12" text-anchor="middle">layout.run_sa_placement(config_bytes)</text>
  <text x="176" y="311" fill="#3E5E80" font-size="11" text-anchor="middle">bytes (raw SaConfig struct) → C pointer</text>

  <rect x="38" y="330" width="276" height="42" rx="4" fill="#0D1E36" stroke="#14263E"/>
  <text x="176" y="348" fill="#B8D0E8" font-size="12" text-anchor="middle">spout.liberty_generate(gds, spice, ...)</text>
  <text x="176" y="363" fill="#3E5E80" font-size="11" text-anchor="middle">module-level function, C-null-terminated args</text>

  <rect x="38" y="382" width="276" height="42" rx="4" fill="#0D1E36" stroke="#14263E"/>
  <text x="176" y="400" fill="#B8D0E8" font-size="12" text-anchor="middle">SaConfig.to_ffi_bytes()</text>
  <text x="176" y="415" fill="#3E5E80" font-size="11" text-anchor="middle">ctypes struct → raw bytes → pyoz.Bytes</text>

  <rect x="38" y="434" width="276" height="60" rx="4" fill="#0D1E36" stroke="#1E88E5"/>
  <text x="176" y="454" fill="#1E88E5" font-size="11" font-weight="600" text-anchor="middle">Error Propagation</text>
  <text x="176" y="470" fill="#B8D0E8" font-size="11" text-anchor="middle">Zig error → i32 return code</text>
  <text x="176" y="484" fill="#B8D0E8" font-size="11" text-anchor="middle">!void → PyOZ raises Python Exception</text>

  <!-- C ABI Boundary (center) -->
  <rect x="365" y="55" width="120" height="460" rx="6" fill="#0D1624" stroke="#14263E" stroke-width="1.5"/>
  <line x1="425" y1="55" x2="425" y2="515" stroke="#00C4E8" stroke-width="1.5" stroke-dasharray="8,4"/>
  <text x="425" y="285" fill="#00C4E8" font-size="12" font-weight="700" text-anchor="middle" transform="rotate(-90, 425, 285)">C ABI Boundary</text>

  <!-- Arrows across boundary -->
  <line x1="314" y1="131" x2="485" y2="131" stroke="#00C4E8" stroke-width="1.5" marker-end="url(#arr)"/>
  <line x1="314" y1="183" x2="485" y2="183" stroke="#00C4E8" stroke-width="1.5" marker-end="url(#arr)"/>
  <line x1="314" y1="250" x2="485" y2="250" stroke="#00C4E8" stroke-width="1.5" marker-end="url(#arr)"/>
  <line x1="314" y1="299" x2="485" y2="299" stroke="#00C4E8" stroke-width="1.5" marker-end="url(#arr)"/>
  <line x1="314" y1="349" x2="485" y2="349" stroke="#00C4E8" stroke-width="1.5" marker-end="url(#arr)"/>

  <!-- Return arrows (right to left, red for errors) -->
  <line x1="485" y1="165" x2="314" y2="165" stroke="#43A047" stroke-width="1" marker-end="url(#arrs)" stroke-dasharray="3,2"/>
  <line x1="485" y1="270" x2="314" y2="270" stroke="#43A047" stroke-width="1" marker-end="url(#arrs)" stroke-dasharray="3,2"/>
  <line x1="485" y1="320" x2="314" y2="320" stroke="#EF5350" stroke-width="1" marker-end="url(#arrs)" stroke-dasharray="3,2"/>
  <text x="345" y="316" fill="#EF5350" font-size="9">error</text>

  <!-- Zig Side (right) -->
  <rect x="500" y="55" width="580" height="460" rx="8" fill="#0A1825" stroke="#14263E" stroke-width="1.5"/>
  <text x="790" y="80" fill="#43A047" font-size="14" font-weight="700" text-anchor="middle">Zig Implementation</text>
  <text x="790" y="98" fill="#3E5E80" font-size="11" text-anchor="middle">src/python_ext.zig + src/lib.zig</text>

  <!-- Zig code boxes -->
  <rect x="518" y="110" width="545" height="42" rx="4" fill="#0D1E36" stroke="#14263E"/>
  <text x="790" y="127" fill="#43A047" font-size="12" text-anchor="middle">PyOZ module(.{ .name = "spout", .classes = Layout, ... })</text>
  <text x="790" y="143" fill="#3E5E80" font-size="11" text-anchor="middle">SpoutPythonModule — emitted as spout.so / spout.cpython-XY.so</text>

  <rect x="518" y="162" width="545" height="54" rx="4" fill="#0D1E36" stroke="#14263E"/>
  <text x="790" y="180" fill="#43A047" font-size="12" text-anchor="middle">Layout.__new__(backend: u8, pdk_id: u8) !Layout</text>
  <text x="790" y="196" fill="#3E5E80" font-size="11" text-anchor="middle">Calls spout_init_layout(backend, pdk_id)</text>
  <text x="790" y="211" fill="#3E5E80" font-size="11" text-anchor="middle">Returns opaque *anyopaque handle; error.InitFailed if null</text>

  <rect x="518" y="226" width="545" height="42" rx="4" fill="#0D1E36" stroke="#14263E"/>
  <text x="790" y="244" fill="#43A047" font-size="12" text-anchor="middle">fn parse_netlist(self, path: []const u8) !void</text>
  <text x="790" y="260" fill="#3E5E80" font-size="11" text-anchor="middle">spout_parse_netlist(handle, path.ptr, path.len) → 0 on success</text>

  <rect x="518" y="278" width="545" height="42" rx="4" fill="#0D1E36" stroke="#14263E"/>
  <text x="790" y="296" fill="#43A047" font-size="12" text-anchor="middle">fn run_sa_placement(self, config: pyoz.Bytes) !void</text>
  <text x="790" y="311" fill="#3E5E80" font-size="11" text-anchor="middle">config.data.ptr / config.data.len → spout_run_sa_placement</text>

  <rect x="518" y="330" width="545" height="42" rx="4" fill="#0D1E36" stroke="#14263E"/>
  <text x="790" y="348" fill="#43A047" font-size="12" text-anchor="middle">fn liberty_generate(gds, spice, cell, pdk_id, corner, output)</text>
  <text x="790" y="363" fill="#3E5E80" font-size="11" text-anchor="middle">alloc.dupeZ() each string → C null-terminated; spout_liberty_generate</text>

  <rect x="518" y="382" width="545" height="42" rx="4" fill="#0D1E36" stroke="#14263E"/>
  <text x="790" y="400" fill="#43A047" font-size="12" text-anchor="middle">SpoutContext (heap-allocated, opaque to Python)</text>
  <text x="790" y="415" fill="#3E5E80" font-size="11" text-anchor="middle">devices, nets, pins, constraints, routes, pdk — all SoA arrays</text>

  <rect x="518" y="434" width="545" height="60" rx="4" fill="#0D1E36" stroke="#43A047"/>
  <text x="790" y="454" fill="#43A047" font-size="11" font-weight="600" text-anchor="middle">Memory Ownership</text>
  <text x="790" y="470" fill="#B8D0E8" font-size="11" text-anchor="middle">Zig owns ALL memory inside SpoutContext</text>
  <text x="790" y="484" fill="#B8D0E8" font-size="11" text-anchor="middle">__del__ calls spout_destroy() — full recursive free</text>

  <!-- Arrow markers -->
  <defs>
    <marker id="arr" markerWidth="8" markerHeight="8" refX="7" refY="3" orient="auto">
      <path d="M0,0 L0,6 L8,3 z" fill="#00C4E8"/>
    </marker>
    <marker id="arrs" markerWidth="8" markerHeight="8" refX="7" refY="3" orient="auto">
      <path d="M0,0 L0,6 L8,3 z" fill="#43A047"/>
    </marker>
  </defs>
</svg>

---

## Build System

**File:** `build.zig`

The native Python extension is built with:

```
zig build pyext
```

This compiles `src/python_ext.zig` as a shared library, links it against the PyOZ dependency (`PyOZ-0.12.2`) and the spout core module (`src/lib.zig`), and installs the result as `python/spout.so`.

**Dependencies** (`build.zig.zon`):
- Project name: `spout2`, version `0.1.0`
- Single dependency: `PyOZ` v0.12.2 from `https://github.com/pyozig/PyOZ/releases/download/v0.12.2/PyOZ-0.12.2.tar.gz`
- SHA-256: `dc488941dd07c5d41ff7fc8f450b51ea77a01158e4299ea2ce7d8035a3d274d5`

**Two build outputs:**
1. `zig-out/lib/libspout.so` — The raw C-ABI shared library (for ctypes use, installed to `python/libspout.so`)
2. `python/spout.so` — The native CPython extension (built with `zig build pyext`, preferred interface)

The cpython extension replaces the older ctypes approach. Python code does `import spout` and gets the extension module directly.

---

## Module Definition

**File:** `src/python_ext.zig`

```zig
pub const SpoutPythonModule = pyoz.module(.{
    .name = "spout",
    .doc = "Spout analog IC layout automation — native Python extension",
    .classes = &.{
        pyoz.class("Layout", Layout),
    },
    .funcs = &.{
        pyoz.func("liberty_generate", liberty_generate,
            "Generate a Liberty (.lib) file for one PVT corner"),
        pyoz.func("liberty_generate_all_corners", liberty_generate_all_corners,
            "Generate Liberty files for all PVT corners; returns file count"),
    },
});
```

This registers:
- One class: `Layout` (exposed as `spout.Layout`)
- Two module-level functions: `spout.liberty_generate`, `spout.liberty_generate_all_corners`

---

## The `Layout` Class

### Constructor: `__new__`

```zig
pub fn __new__(backend: u8, pdk_id: u8) !Layout
```

**Python call:**
```python
layout = spout.Layout(0, 0)  # backend=magic(0), pdk=sky130(0)
```

**Zig implementation:**
1. Calls `lib.spout_init_layout(backend, pdk_id)`
2. Returns `error.InitFailed` if the handle is null
3. Stores the opaque `*anyopaque` handle in `_handle`

**What `spout_init_layout` does internally:**
- Selects PDK (sky130=0, gf180=1, ihp130=2)
- Calls `layout_if.PdkConfig.loadDefault(pdk_id_typed)` — loads bundled JSON PDK config
- Allocates a `SpoutContext` on the heap via `std.heap.page_allocator`
- Initializes all SoA arrays (DeviceArrays, NetArrays, PinEdgeArrays, ConstraintArrays) to empty
- Sets all optional fields (routes, adj, macros, drc_violations, pex_result, template_context) to null

**Note:** `backend` parameter is accepted but currently unused at runtime — the backend selection is handled at compile time by the GDS writer. The parameter exists for API compatibility.

### Destructor: `__del__`

```zig
pub fn __del__(self: *Layout) void {
    lib.spout_destroy(self._handle);
}
```

Called automatically when the Python object is garbage collected. `spout_destroy` performs a full recursive free:
- Frees route_segments_flat, layout_connectivity, macro_inst_tmpl_ids, macro_inst_positions
- Calls `m.deinit()` on macros
- Calls `pr.deinit()` on parse_result
- Frees drc_violations
- Calls `p.deinit()` then `destroy` on pex_result
- Calls `tc.deinit()` then `destroy` on template_context
- Deinits adj, routes, constraints, pins, nets, devices in reverse order
- Destroys the SpoutContext itself

---

## Layout Methods

### PDK Management

#### `load_pdk_from_file(path: str) -> None`

```zig
pub fn load_pdk_from_file(self: *Layout, path: []const u8) !void {
    if (lib.spout_load_pdk_from_file(self._handle, path.ptr, path.len) != 0)
        return error.PdkLoadFailed;
}
```

**C function:** `spout_load_pdk_from_file(handle, path_ptr, path_len) i32`
- Returns 0 on success, -1 on invalid handle, -4 on file or parse error.
- Replaces the current PDK configuration by reading a JSON file at `path`.
- Call immediately after `Layout()` to use a custom or cloned PDK JSON.
- After this call, all device dimension computations, DRC rules, and routing parameters use the new PDK.

---

### Netlist Parsing

#### `parse_netlist(path: str) -> None`

```zig
pub fn parse_netlist(self: *Layout, path: []const u8) !void {
    if (lib.spout_parse_netlist(self._handle, path.ptr, path.len) != 0)
        return error.ParseFailed;
}
```

**C function:** `spout_parse_netlist(handle, path_ptr, path_len) i32`
- Returns 0 on success, -1 invalid handle, -2 parse error, -3 allocation error, -4 adjacency build error.

**What happens internally:**
1. Discards any previous parse result
2. Resets all SoA arrays (devices, nets, pins) and derived state (macros, adj)
3. Creates a `Parser` and calls `p.parseFile(path)`
4. Populates DeviceArrays, NetArrays, PinEdgeArrays from parse result
5. Calls `pins.computePinOffsets(&ctx.devices)` — computes spatial positions for each terminal (gate, source, drain, body) relative to the device center
6. Calls `computeDeviceDimensions(&ctx.devices, &ctx.pdk)` — computes bounding-box dimensions in µm for each device including all geometry layers
7. Calls `FlatAdjList.build()` — builds the connectivity adjacency list from pin arrays
8. Calls `macro_mod.detectMacros()` — auto-detects macros (current mirrors, differential pairs, etc.)
9. Stores the parse result alive for the lifetime of the context

**Supported netlist formats:** SPICE `.spice`, `.sp`, `.cdl` with `.subckt` definitions.

#### `get_num_devices() -> int`

```zig
pub fn get_num_devices(self: *const Layout) u32 {
    return lib.spout_get_num_devices(self._handle);
}
```

Returns the number of devices in the parsed netlist. Returns 0 if not yet parsed.

#### `get_num_nets() -> int`

```zig
pub fn get_num_nets(self: *const Layout) u32 {
    return lib.spout_get_num_nets(self._handle);
}
```

Returns the number of nets in the parsed netlist.

#### `get_num_pins() -> int`

```zig
pub fn get_num_pins(self: *const Layout) u32 {
    return lib.spout_get_num_pins(self._handle);
}
```

Returns the total number of pin-edges (device-terminal-to-net connections).

---

### Constraint Extraction

#### `extract_constraints() -> None`

```zig
pub fn extract_constraints(self: *Layout) !void {
    if (lib.spout_extract_constraints(self._handle) != 0)
        return error.ConstraintFailed;
}
```

**C function:** `spout_extract_constraints(handle) i32`
- Returns 0 on success, -1 invalid handle, -2 no adjacency (parse not called), -3 extraction error.

Runs the constraint extraction algorithm on the adjacency graph. Produces:
- `symmetry` constraints for differential pairs (weight 1.0)
- `matching` constraints for current mirrors (weight 0.8)
- `proximity` constraints for cascodes (weight 0.6)

The constraint data drives the SA placer cost function.

---

### Placement

#### `run_sa_placement(config: bytes) -> None`

```zig
pub fn run_sa_placement(self: *Layout, config: pyoz.Bytes) !void {
    if (lib.spout_run_sa_placement(self._handle, config.data.ptr, config.data.len) != 0)
        return error.PlacementFailed;
}
```

**Parameter:** `config` must be a Python `bytes` object containing a raw `SaConfig` C struct. Produced by `SaConfig.to_ffi_bytes()`.

**C function:** `spout_run_sa_placement(handle, config_ptr, config_len) i32`
- Returns 0 on success, -1 invalid handle, -3 allocation error.

**What happens internally:**
1. If `config_len == sizeof(SaConfig)`, interprets the bytes as a raw `SaConfig` struct via `@ptrCast`
2. If template context is loaded, overrides SA bounds with template user-area bounds
3. Computes per-device bounding-box center offsets (NMOS/PMOS geometry from PDK constants)
4. Shifts device positions to bounding-box centers for SA
5. Builds placer-local pin info with offsets adjusted for the center shift
6. Runs the SA optimizer (`sa.runSa()`)
7. Shifts positions back from bounding-box centers to layout origins

The `SaConfig` struct layout (must match exactly):
```c
typedef struct {
    float initialTemp;          // default: 1000.0
    float coolingRate;          // default: 0.995
    float minTemp;              // default: 0.01
    uint32_t maxIterations;     // default: 50000
    float perturbationRange;    // default: 10.0 (microns)
    float wHpwl;                // default: 1.0
    float wArea;                // default: 0.5
    float wSymmetry;            // default: 2.0
    float wMatching;            // default: 1.5
    float wRudy;                // default: 0.3
    float wOverlap;             // default: 100.0
    float wThermal;             // default: 0.0
    float wTiming;              // default: 0.3
    float wEmbedSimilarity;     // default: 0.5
    float wParasitic;           // default: 0.2
    uint8_t adaptiveCooling;    // default: 1 (true)
    uint32_t adaptiveWindow;    // default: 500
    uint32_t maxReheats;        // default: 5
    float reheatFraction;       // default: 0.3
    uint32_t stallWindowsBeforeReheat; // default: 3
    uint32_t numStarts;         // default: 1
    float delayDriverR;         // default: 500.0 (Ohm)
    float delayWireRPerUm;      // default: 0.125 (Ohm/µm)
    float delayWireCPerUm;      // default: 0.2 (fF/µm)
    float delayPinC;            // default: 1.0 (fF)
} SaConfig;
```

#### `get_placement_cost() -> float`

```zig
pub fn get_placement_cost(self: *const Layout) f32 {
    return lib.spout_get_placement_cost(self._handle);
}
```

Returns the final SA cost after placement. Lower is better. Returns 0.0 if placement has not been run.

---

### Routing

#### `run_routing() -> None`

```zig
pub fn run_routing(self: *Layout) !void {
    if (lib.spout_run_routing(self._handle) != 0)
        return error.RoutingFailed;
}
```

**C function:** `spout_run_routing(handle) i32`
- Returns 0 on success.

Runs the maze router. Uses device positions from the SA placer, PDK layer definitions, and constraint data. Produces route segments stored in the context's `routes` field.

#### `get_num_routes() -> int`

```zig
pub fn get_num_routes(self: *const Layout) u32 {
    return lib.spout_get_num_routes(self._handle);
}
```

Returns the number of route segments generated by the router.

---

### GDSII Export

#### `export_gdsii(path: str) -> None`

```zig
pub fn export_gdsii(self: *Layout, path: []const u8) !void {
    if (lib.spout_export_gdsii(self._handle, path.ptr, path.len) != 0)
        return error.ExportFailed;
}
```

Exports GDSII to `path` using an auto-generated cell name (derived from the output file path stem).

#### `export_gdsii_named(path: str, name: Optional[str]) -> None`

```zig
pub fn export_gdsii_named(self: *Layout, path: []const u8, name: ?[]const u8) !void {
    const name_ptr: ?[*]const u8 = if (name) |n| n.ptr else null;
    const name_len: usize = if (name) |n| n.len else 0;
    if (lib.spout_export_gdsii_named(self._handle, path.ptr, path.len, name_ptr, name_len) != 0)
        return error.ExportFailed;
}
```

Exports GDSII with explicit cell name. Pass `None` for `name` to use auto-detection.

#### `export_gdsii_with_template(output_path: str, user_cell_name: str, top_cell_name: str) -> None`

```zig
pub fn export_gdsii_with_template(
    self: *const Layout,
    output_path: []const u8,
    user_cell_name: []const u8,
    top_cell_name: []const u8,
) !void
```

Hierarchical GDSII export that merges the user circuit with a pre-loaded GDS template. Uses `alloc.dupeZ()` to create null-terminated copies of all strings before calling the C function. Returns `error.ExportFailed` if the C function returns non-zero.

---

### DRC

#### `run_drc() -> None`

```zig
pub fn run_drc(self: *Layout) !void {
    if (lib.spout_run_drc(self._handle) != 0)
        return error.DrcFailed;
}
```

Runs the in-engine DRC (inline DRC). Distinct from the KLayout signoff DRC called by `python/tools.py:run_klayout_drc()`.

#### `get_num_violations() -> int`

```zig
pub fn get_num_violations(self: *const Layout) u32 {
    return lib.spout_get_num_violations(self._handle);
}
```

Returns the number of DRC violations found by the in-engine DRC.

---

### LVS

#### `run_lvs() -> None`

```zig
pub fn run_lvs(self: *Layout) !void {
    if (lib.spout_run_lvs(self._handle) != 0)
        return error.LvsFailed;
}
```

Runs the in-engine LVS (layout vs schematic check).

#### `get_lvs_match() -> bool`

```zig
pub fn get_lvs_match(self: *const Layout) bool {
    return lib.spout_get_lvs_match(self._handle);
}
```

Returns `True` if the in-engine LVS found a netlist match.

#### `get_lvs_mismatch_count() -> int`

```zig
pub fn get_lvs_mismatch_count(self: *const Layout) u32 {
    return lib.spout_get_lvs_mismatch_count(self._handle);
}
```

Returns the number of LVS mismatches.

---

### PEX

#### `run_pex() -> None`

```zig
pub fn run_pex(self: *Layout) !void {
    if (lib.spout_run_pex(self._handle) != 0)
        return error.PexFailed;
}
```

Runs the in-engine PEX (parasitic extraction).

#### `get_pex_totals() -> tuple[int, int, float, float]`

```zig
pub fn get_pex_totals(self: *const Layout) !struct { u32, u32, f32, f32 } {
    var num_res: u32 = 0;
    var num_cap: u32 = 0;
    var total_res: f32 = 0;
    var total_cap: f32 = 0;
    if (lib.spout_get_pex_totals(self._handle, &num_res, &num_cap, &total_res, &total_cap) != 0)
        return error.PexResultFailed;
    return .{ num_res, num_cap, total_res, total_cap };
}
```

Returns a 4-tuple: `(num_res, num_cap, total_res_ohm, total_cap_ff)`.

**Data marshaling:** The C function writes to four output pointers. PyOZ marshals the 4-element anonymous struct as a Python tuple.

#### `ext2spice(path: str) -> None`

```zig
pub fn ext2spice(self: *Layout, path: []const u8) !void {
    if (lib.spout_ext2spice(self._handle, path.ptr, path.len) != 0)
        return error.Ext2SpiceFailed;
}
```

Writes the layout SPICE netlist with parasitics to the given path.

#### `generate_layout_spice(path: str) -> None`

```zig
pub fn generate_layout_spice(self: *Layout, path: []const u8) !void {
    if (lib.spout_generate_layout_spice(self._handle, path.ptr, path.len) != 0)
        return error.GenerateFailed;
}
```

Generates a SPICE netlist representing the current layout (post-placement, post-routing) without running full PEX.

---

### GDS Template Operations

#### `load_template_gds(gds_path: str, cell_name: Optional[str]) -> None`

```zig
pub fn load_template_gds(self: *Layout, gds_path: []const u8, cell_name: ?[]const u8) !void {
    const alloc = std.heap.c_allocator;
    const gds_z = try alloc.dupeZ(u8, gds_path);
    defer alloc.free(gds_z);
    var cell_z: ?[:0]u8 = null;
    if (cell_name) |cn| cell_z = try alloc.dupeZ(u8, cn);
    defer if (cell_z) |cz| alloc.free(cz);
    const cell_ptr: ?[*:0]const u8 = if (cell_z) |cz| cz.ptr else null;
    if (lib.spout_load_template_gds(self._handle, gds_z.ptr, cell_ptr) != 0)
        return error.TemplateLoadFailed;
}
```

Loads a GDS template file. If `cell_name` is `None`, the largest cell in the template is selected automatically. The PyOZ optional string maps to a nullable C pointer.

**String marshaling:** PyOZ `[]const u8` slices are NOT null-terminated. The Zig wrapper allocates null-terminated copies via `alloc.dupeZ()` (using `std.heap.c_allocator`) before passing to the C function. These are freed immediately after the call.

#### `get_template_bounds() -> tuple[float, float, float, float]`

```zig
pub fn get_template_bounds(self: *const Layout) !struct { f32, f32, f32, f32 } {
    var xmin: f32 = 0;
    var ymin: f32 = 0;
    var xmax: f32 = 0;
    var ymax: f32 = 0;
    if (lib.spout_get_template_bounds(self._handle, &xmin, &ymin, &xmax, &ymax) != 0)
        return error.TemplateBoundsFailed;
    return .{ xmin, ymin, xmax, ymax };
}
```

Returns `(xmin, ymin, xmax, ymax)` in microns as a Python tuple. Call after `load_template_gds()`.

---

## Module-Level Functions

### `spout.liberty_generate(gds_path, spice_path, cell_name, pdk_id, corner_name, output_path) -> None`

```zig
fn liberty_generate(
    gds_path: []const u8,
    spice_path: []const u8,
    cell_name: []const u8,
    pdk_id: i32,
    corner_name: []const u8,
    output_path: []const u8,
) !void
```

Generates a Liberty (`.lib`) timing file for one PVT corner. All string arguments are converted to null-terminated C strings via `alloc.dupeZ()` before calling `lib.spout_liberty_generate(...)`. Memory is freed immediately after the call.

**Error:** Returns `error.LibertyFailed` if the C function returns non-zero.

### `spout.liberty_generate_all_corners(gds_path, spice_path, cell_name, pdk_id, output_dir) -> int`

```zig
fn liberty_generate_all_corners(
    gds_path: []const u8,
    spice_path: []const u8,
    cell_name: []const u8,
    pdk_id: i32,
    output_dir: []const u8,
) !u32
```

Generates Liberty files for all PVT corners. Returns the number of generated `.lib` files. The C function writes the count to a `u32` output pointer. Returns `error.LibertyFailed` on error.

---

## Memory Management Across the FFI Boundary

### Ownership Rules

| Object                     | Owner  | Lifetime                                      |
| -------------------------- | ------ | --------------------------------------------- |
| `SpoutContext`             | Zig    | Created at `__new__`, freed at `__del__`       |
| `DeviceArrays`             | Zig    | Freed at `__del__` or next `parse_netlist()`   |
| `SaConfig bytes` (input)   | Python | Only needed for the duration of the call       |
| Route segments             | Zig    | Freed at `__del__`                             |
| FFI flat buffers (Spans)   | Zig    | Valid until next mutating call                 |
| Null-terminated strings    | Zig    | Heap-allocated, freed immediately after use    |
| Parse result               | Zig    | Freed at `__del__` or next `parse_netlist()`   |

### String Marshaling Detail

PyOZ passes Python strings as `[]const u8` slices (pointer + length, NOT null-terminated). Functions that pass strings to the C layer must create null-terminated copies:

```zig
const gds_z = try alloc.dupeZ(u8, gds_path);
defer alloc.free(gds_z);
```

Functions that accept `[]const u8` and only call Zig functions (e.g., `parse_netlist`, `export_gdsii`) do NOT need null termination — the Zig API accepts length-delimited slices.

### SA Config Binary Marshaling

`SaConfig.to_ffi_bytes()` in `python/config.py` uses ctypes to serialize the Python dataclass to the exact binary layout of the Zig `SaConfig` extern struct:

```python
bytes(_SaConfigC(
    initialTemp=self.initial_temp,
    coolingRate=self.cooling_rate,
    ...
))
```

The C struct `_SaConfigC` mirrors the Zig `SaConfig` field-for-field, using ctypes types that match the Zig types: `c_float` for `f32`, `c_uint32` for `u32`, `c_uint8` for `u8`.

On the Zig side, the bytes are reinterpreted via:
```zig
if (config_len == @sizeOf(sa.SaConfig)) {
    const cfg_bytes = config_ptr[0..@sizeOf(sa.SaConfig)];
    sa_config = @as(*align(1) const sa.SaConfig, @ptrCast(cfg_bytes)).*;
}
```

The `align(1)` cast handles potentially unaligned byte buffers from Python.

---

## Error Handling

### Zig Error → Python Exception Propagation

PyOZ maps Zig error unions to Python exceptions:

| Zig error                  | Python exception      | Trigger condition                              |
| -------------------------- | --------------------- | ---------------------------------------------- |
| `error.InitFailed`         | `RuntimeError`        | `spout_init_layout` returns null               |
| `error.PdkLoadFailed`      | `RuntimeError`        | `spout_load_pdk_from_file` returns non-zero    |
| `error.ParseFailed`        | `RuntimeError`        | `spout_parse_netlist` returns non-zero         |
| `error.ConstraintFailed`   | `RuntimeError`        | `spout_extract_constraints` returns non-zero   |
| `error.PlacementFailed`    | `RuntimeError`        | `spout_run_sa_placement` returns non-zero      |
| `error.RoutingFailed`      | `RuntimeError`        | `spout_run_routing` returns non-zero           |
| `error.ExportFailed`       | `RuntimeError`        | `spout_export_gdsii*` returns non-zero         |
| `error.DrcFailed`          | `RuntimeError`        | `spout_run_drc` returns non-zero               |
| `error.LvsFailed`          | `RuntimeError`        | `spout_run_lvs` returns non-zero               |
| `error.PexFailed`          | `RuntimeError`        | `spout_run_pex` returns non-zero               |
| `error.LibertyFailed`      | `RuntimeError`        | `spout_liberty_generate*` returns non-zero     |
| `error.TemplateLoadFailed` | `RuntimeError`        | `spout_load_template_gds` returns non-zero     |
| `error.TemplateBoundsFailed` | `RuntimeError`      | `spout_get_template_bounds` returns non-zero   |
| `error.OutOfMemory`        | `MemoryError`         | Any `alloc.dupeZ` fails                        |

### C Function Return Codes

All C functions return `i32` with the convention:
- `0` = success
- `-1` = invalid handle or uninitialized context
- `-2` = prerequisite not met (e.g., parse before constraints)
- `-3` = memory allocation failure
- `-4` = file I/O or parse error

---

## Complete Working Examples

### Full Pipeline (Python)

```python
import spout
from spout.config import SpoutConfig, SaConfig
from spout.main import run_pipeline

# Option 1: High-level pipeline API (recommended)
config = SpoutConfig(
    backend="magic",
    pdk="sky130",
    sa_config=SaConfig(
        initial_temp=1000.0,
        cooling_rate=0.995,
        max_iterations=50_000,
        w_symmetry=2.0,
        w_matching=1.5,
        w_overlap=100.0,
    ),
)
result = run_pipeline("my_circuit.spice", config, output_path="my_circuit.gds")
print(f"DRC violations: {result.drc_violations}")
print(f"LVS clean: {result.lvs_clean}")
print(f"Total time: {result.timings.total:.2f}s")
```

### Low-Level spout.Layout API

```python
import spout
from spout.config import SaConfig

# Create layout handle (magic backend=0, sky130 PDK=0)
layout = spout.Layout(0, 0)

# Optionally override PDK from file
layout.load_pdk_from_file("/path/to/custom.json")

# Parse netlist
layout.parse_netlist("my_diff_pair.spice")
print(f"Devices: {layout.get_num_devices()}, Nets: {layout.get_num_nets()}")

# Extract constraints (detects diff pairs, current mirrors, cascodes)
layout.extract_constraints()

# Build SA config and run placement
sa = SaConfig(w_symmetry=2.0, w_overlap=100.0)
layout.run_sa_placement(sa.to_ffi_bytes())
print(f"Placement cost: {layout.get_placement_cost():.4f}")

# Route
layout.run_routing()
print(f"Route segments: {layout.get_num_routes()}")

# Export GDS
layout.export_gdsii_named("output.gds", "diff_pair")

# Cleanup happens automatically when layout goes out of scope (GC calls __del__)
```

### Template-Based Export (TinyTapeout)

```python
import spout

layout = spout.Layout(0, 0)  # magic, sky130
layout.parse_netlist("my_analog.spice")
layout.extract_constraints()

# Load TinyTapeout template
layout.load_template_gds("tt_um_wrapper.gds", "user_project_wrapper")
bounds = layout.get_template_bounds()
print(f"User area: {bounds[0]:.1f} to {bounds[2]:.1f} µm, "
      f"{bounds[1]:.1f} to {bounds[3]:.1f} µm")

sa = SaConfig(perturbation_range=5.0)  # tight for small tile
layout.run_sa_placement(sa.to_ffi_bytes())
layout.run_routing()

# Hierarchical export: creates top → user_project_wrapper + user_analog_circuit
layout.export_gdsii_with_template("submission.gds", "user_analog_circuit", "top")
```

### Liberty File Generation

```python
import spout

# Single PVT corner
spout.liberty_generate(
    "my_cell.gds",
    "my_cell.spice",
    "my_cell",
    0,                    # pdk_id: 0=sky130, 1=gf180, 2=ihp130
    "tt_025C_1v80",       # corner name
    "my_cell_tt.lib",     # output path
)

# All corners
n = spout.liberty_generate_all_corners(
    "my_cell.gds",
    "my_cell.spice",
    "my_cell",
    0,           # pdk_id
    "lib_output" # output directory
)
print(f"Generated {n} Liberty files")
```

---

## How the Shared Library Is Loaded

When `import spout` is executed from Python:

1. Python searches `sys.path` for `spout.so` or `spout.cpython-XY-linux-gnu.so`
2. The `python/` directory is either on `sys.path` (set by pytest conftest.py or benchmark.py) or installed as a package
3. `zig build pyext` installs the extension to `python/spout.so` using `addInstallFileWithDir`
4. PyOZ's module entry point (`PyInit_spout`) registers the `Layout` class and module functions

The ctypes path (using `libspout.so` directly) is the legacy path. The PyOZ extension module is the preferred interface.
