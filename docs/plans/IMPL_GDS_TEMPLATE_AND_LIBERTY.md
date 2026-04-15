# Implementation Plan: GDS Template Input + Liberty File Production

## Overview

Two major features, implemented in parallel across 5 agents.

- **TODO 1**: GDS template input (TinyTapeout integration) — full new subsystem
- **TODO 2**: Liberty file production — integration/CLI layer over existing ~85% skeleton

---

## TODO 1: GDS Template Input

### Architecture

```
.gds template file
       │
       ▼
src/import/gdsii.zig       ← NEW: binary GDSII reader
       │
       ▼
src/import/template.zig    ← NEW: TemplateContext struct
       │
       ├──► src/placer/sa.zig     (PlacementRegion hard bounds)
       ├──► src/router/grid.zig   (BlockedRegion cell marking)
       └──► src/export/gdsii.zig  (SREF emission for template ref)
                   │
                   ▼
src/lib.zig  (C-ABI: load_template_gds, get_template_bounds)
                   │
                   ▼
python/main.py  (template_gds pipeline parameter)
```

### Phase 1: GDSII Binary Reader — `src/import/gdsii.zig`

**GDSII Binary Format:**
```
Each record:
  [u16 big-endian: total_length]  (includes 4-byte header)
  [u8: record_type]
  [u8: data_type]
  [payload...]

Data type codes:
  0x00 = no data
  0x02 = u16 array
  0x03 = i32 array
  0x05 = GDSII real (8-byte, excess-64 base-16)
  0x06 = ASCII string
```

**Record types to handle:**
| Record | Code | Action |
|--------|------|--------|
| HEADER | 0x0002 | Skip (version) |
| BGNLIB | 0x0102 | Record library timestamp |
| LIBNAME | 0x0206 | Store library name |
| UNITS | 0x0305 | Parse db_unit and user_unit |
| BGNSTR | 0x0502 | Begin new cell |
| STRNAME | 0x0606 | Store cell name |
| BOUNDARY | 0x0800 | Parse polygon, update bbox |
| PATH | 0x0900 | Parse path, update bbox |
| SREF | 0x0A00 | Record sub-cell reference |
| AREF | 0x0B00 | Record array reference |
| TEXT | 0x0C00 | Record net label (pin) |
| LAYER | 0x0D02 | Current layer |
| DATATYPE | 0x0E02 | Current datatype |
| WIDTH | 0x0F03 | Current path width |
| XY | 0x1003 | Current coordinates |
| ENDEL | 0x1100 | End element |
| ENDSTR | 0x0700 | End cell → push TemplateCell |
| ENDLIB | 0x0400 | End file |
| SNAME | 0x1206 | SREF cell name |
| STRING | 0x1906 | Text content (pin label) |
| PROPATTR | 0x2B02 | Property attribute (skip or parse) |
| PROPVALUE | 0x2C06 | Property value (skip or parse) |

**GDSII Real Conversion (excess-64 base-16):**
```zig
fn gdsRealToF64(bytes: [8]u8) f64 {
    const sign: bool = (bytes[0] & 0x80) != 0;
    const exp: i32 = @as(i32, bytes[0] & 0x7F) - 64;
    var mantissa: u64 = 0;
    for (1..8) |i| {
        mantissa = (mantissa << 8) | bytes[i];
    }
    const f = @as(f64, @floatFromInt(mantissa)) * std.math.pow(f64, 16.0, @floatFromInt(exp - 14));
    return if (sign) -f else f;
}
```

**Public API:**
```zig
pub const GdsReader = struct {
    pub fn readFromFile(path: []const u8, allocator: Allocator) !GdsLibrary
    pub fn deinit(self: *GdsReader) void
};

pub const GdsLibrary = struct {
    name: []const u8,
    db_unit: f64,       // meters per database unit
    user_unit: f64,     // meters per user unit
    cells: []GdsCell,
    allocator: Allocator,
    pub fn findCell(self: *const GdsLibrary, name: []const u8) ?*const GdsCell
    pub fn deinit(self: *GdsLibrary) void
};

pub const GdsCell = struct {
    name: []const u8,
    bbox: [4]f64,       // [x_min, y_min, x_max, y_max] in µm
    has_bbox: bool,
    pins: []GdsPin,     // TEXT labels with layer
    refs: []GdsSref,    // Sub-cell references
    polygon_count: u32,
    allocator: Allocator,
};

pub const GdsPin = struct {
    name: []const u8,
    layer: u16,
    datatype: u16,
    x: f64,
    y: f64,
};

pub const GdsSref = struct {
    cell_name: []const u8,
    x: f64,
    y: f64,
    angle: f64,        // degrees
    magnification: f64,
    reflect: bool,
};
```

### Phase 2: TemplateContext — `src/import/template.zig`

```zig
pub const TemplatePinDir = enum { input, output, inout, power, ground };

pub const TemplatePin = extern struct {
    name: [64]u8,          // Null-terminated pin name
    layer: u16,
    x: f32,                // µm
    y: f32,                // µm
    direction: TemplatePinDir,
};

pub const TemplateCell = extern struct {
    name: [256]u8,          // Null-terminated cell name
    x_min: f32,            // User area bounding box µm
    y_min: f32,
    x_max: f32,
    y_max: f32,
    pin_count: u32,
    // pins pointer managed by TemplateContext
};

pub const TemplateContext = struct {
    library: GdsLibrary,
    user_cell: ?*const GdsCell,    // Primary user area cell
    user_bbox: [4]f32,              // [xmin, ymin, xmax, ymax] µm
    pins: []TemplatePin,
    allocator: Allocator,

    pub fn loadFromGds(path: []const u8, cell_name: ?[]const u8, allocator: Allocator) !TemplateContext
    pub fn getUserAreaBounds(self: *const TemplateContext) [4]f32
    pub fn getAnalogPins(self: *const TemplateContext) []const TemplatePin
    pub fn deinit(self: *TemplateContext) void
};
```

### Phase 3: Placer Template Bounds — `src/placer/sa.zig` + `src/placer/cost.zig`

**Add to SaConfig (extern struct, C-ABI compatible):**
```zig
// In SaConfig - new fields at end to preserve ABI:
template_x_min: f32 = 0.0,
template_y_min: f32 = 0.0,
template_x_max: f32 = 1e9,
template_y_max: f32 = 1e9,
use_template_bounds: bool = false,
```

**Hard bound enforcement in `sa.zig` move acceptance:**
```zig
// After computing new_pos, before cost evaluation:
if (config.use_template_bounds) {
    const dev_w = devices.dimensions[idx][0];
    const dev_h = devices.dimensions[idx][1];
    if (new_pos[0] < config.template_x_min or
        new_pos[0] + dev_w > config.template_x_max or
        new_pos[1] < config.template_y_min or
        new_pos[1] + dev_h > config.template_y_max)
    {
        continue; // Reject move, not a cost penalty
    }
}
```

**Initialization — place devices inside template bounds initially:**
```zig
// In initPlacement(), if use_template_bounds:
const w = config.template_x_max - config.template_x_min;
const h = config.template_y_max - config.template_y_min;
// Random uniform within [template_x_min, template_x_max) × [template_y_min, template_y_max)
```

### Phase 4: Router Blocked Regions — `src/router/grid.zig` + `src/router/lib.zig`

**Add to AdvancedRoutingOptions:**
```zig
pub const BlockedRegion = extern struct {
    x_min: f32,    // µm
    y_min: f32,
    x_max: f32,
    y_max: f32,
    layer_mask: u8,  // bitmask of blocked layers (0xFF = all)
};

// In AdvancedRoutingOptions:
blocked_regions: ?[*]const BlockedRegion = null,
num_blocked_regions: u32 = 0,
```

**Grid initialization in `grid.zig`:**
```zig
// After grid cell allocation, mark blocked regions:
for (0..opts.num_blocked_regions) |ri| {
    const reg = opts.blocked_regions.?[ri];
    const xi_min = @as(usize, @intFromFloat(reg.x_min / grid.cell_size));
    const xi_max = @min(grid.nx, @as(usize, @intFromFloat(reg.x_max / grid.cell_size)) + 1);
    const yi_min = @as(usize, @intFromFloat(reg.y_min / grid.cell_size));
    const yi_max = @min(grid.ny, @as(usize, @intFromFloat(reg.y_max / grid.cell_size)) + 1);
    for (yi_min..yi_max) |y| {
        for (xi_min..xi_max) |x| {
            for (0..8) |l| {
                if ((reg.layer_mask >> @intCast(l)) & 1 != 0) {
                    grid.cells[y * grid.nx + x].blocked[l] = true;
                }
            }
        }
    }
}
```

### Phase 5: SREF Export — `src/export/gdsii.zig`

**New SREF-related record types:**
```zig
// Add to RecordType enum:
SREF = 0x0A00,
SNAME = 0x1206,
STRANS = 0x1A02,    // Transform flags (mirror-x)
AANGLE = 0x1C05,    // Rotation angle
AMAG = 0x1B05,      // Magnification
```

**SREF writer function:**
```zig
pub fn writeSref(
    writer: anytype,
    cell_name: []const u8,
    x_db: i32,   // in database units (nm for sky130)
    y_db: i32,
    angle_deg: f64,
    magnification: f64,
    mirror_x: bool,
) !void {
    // SREF header
    try records.writeRecord(writer, .SREF, &[_]u8{});
    // SNAME
    try records.writeStringRecord(writer, .SNAME, cell_name);
    // STRANS (if mirror or non-unit mag)
    if (mirror_x or magnification != 1.0) {
        const strans: u16 = if (mirror_x) 0x8000 else 0x0000;
        try records.writeInt16Record(writer, .STRANS, @bitCast(strans));
        if (magnification != 1.0)
            try records.writeGdsRealRecord(writer, .AMAG, magnification);
    }
    // AANGLE
    if (angle_deg != 0.0)
        try records.writeGdsRealRecord(writer, .AANGLE, angle_deg);
    // XY - single coordinate pair
    var xy: [8]u8 = undefined;
    std.mem.writeInt(i32, xy[0..4], x_db, .big);
    std.mem.writeInt(i32, xy[4..8], y_db, .big);
    try records.writeRecord(writer, .XY, &xy);
    // ENDEL
    try records.writeRecord(writer, .ENDEL, &[_]u8{});
}
```

**Hierarchical export — add to `exportLayout()`:**
```zig
// If template is provided:
// 1. Write user design as separate cell (BGNSTR/ENDSTR)
// 2. Write top-level cell that contains SREF to template + SREF to user design
//    - User design placed at (0,0) within template user area
//    - Template cell referenced at (0,0)
```

### Phase 6: C-ABI Surface — `src/lib.zig`

```zig
// New exported functions:

export fn spout_load_template_gds(
    ctx: *SpoutContext,
    gds_path: [*:0]const u8,
    cell_name: ?[*:0]const u8,   // NULL = auto-detect largest cell
) c_int;  // 0 = ok, negative = error

export fn spout_get_template_bounds(
    ctx: *SpoutContext,
    out_xmin: *f32,
    out_ymin: *f32,
    out_xmax: *f32,
    out_ymax: *f32,
) c_int;

export fn spout_get_template_pin_count(ctx: *SpoutContext) u32;

export fn spout_get_template_pin(
    ctx: *SpoutContext,
    idx: u32,
    out_pin: *TemplatePin,
) c_int;

export fn spout_export_gdsii_with_template(
    ctx: *SpoutContext,
    output_path: [*:0]const u8,
    user_cell_name: [*:0]const u8,
) c_int;
```

### Phase 7: Python Integration — `python/main.py`

```python
# New SpoutConfig field:
@dataclass
class TemplateConfig:
    gds_path: str
    cell_name: Optional[str] = None   # Auto-detect if None
    user_area_layer: int = 236        # TinyTapeout user_area layer

# Extended run_pipeline():
def run_pipeline(
    netlist_path: str,
    config: SpoutConfig,
    output_path: str = "output.gds",
    template_config: Optional[TemplateConfig] = None,
    ffi: Optional[SpoutFFI] = None,
) -> PipelineResult:
    ...
    # After init_layout:
    if template_config:
        ffi.load_template_gds(handle, template_config.gds_path, template_config.cell_name)
        bounds = ffi.get_template_bounds(handle)
        config.sa.template_x_min = bounds[0]
        config.sa.template_y_min = bounds[1]
        config.sa.template_x_max = bounds[2]
        config.sa.template_y_max = bounds[3]
        config.sa.use_template_bounds = True
        # Block template's non-user areas in router
        config.routing.blocked_regions = ffi.get_template_blocked_regions(handle)
    ...
    # Export with template merge if template loaded:
    if template_config:
        ffi.export_gdsii_with_template(handle, output_path, user_cell_name)
    else:
        ffi.export_gdsii(handle, output_path, ...)
```

### Phase 8: TinyTapeout-Specific Support

TinyTapeout uses:
- User area: 160µm × 100µm (1 tile)
- Analog pins on left/right edges (metal layers)
- Power rails: VDD/VSS straps on M4/M5
- `user_project_wrapper` as the top cell name

```python
# python/tinytapeout.py - New file
TINYTAPEOUT_USER_AREA = {"width": 160.0, "height": 100.0}  # µm, 1 tile
TINYTAPEOUT_ANALOG_PINS_LAYER = 68  # M1 layer (GDS 68,20)

def load_tinytapeout_template(gds_path: str) -> TemplateConfig:
    return TemplateConfig(
        gds_path=gds_path,
        cell_name="user_project_wrapper",
    )
```

---

## TODO 2: Liberty File Production

### Architecture

Liberty generator is ~85% complete in Zig. Gaps are integration, CLI, multi-corner automation, error handling, and timing sense.

```
SPICE netlist + GDS file
         │
         ▼
src/liberty/lib.zig         (generateLiberty — EXISTS, needs multi-corner)
    ├── spice_sim.zig        (ngspice harness — EXISTS, needs error handling)
    ├── writer.zig           (Liberty format — EXISTS, needs timing_sense)
    ├── gds_area.zig         (GDS bbox — EXISTS)
    └── pdk.zig              (corner enum — EXISTS)
         │
         ▼
python/liberty.py           (CLI entry point — MISSING)
python/main.py              (liberty subcommand integration — MISSING)
```

### Phase 1: Multi-Corner Automation — `src/liberty/lib.zig`

**Current state:** `generateLiberty()` takes one `LibertyConfig` for one corner.

**Add multi-corner sweep:**
```zig
pub fn generateLibertyAllCorners(
    writer: anytype,
    gds_path: []const u8,
    spice_path: []const u8,
    cell_name: []const u8,
    pdk_id: PdkId,
    allocator: Allocator,
) !void {
    const corner_set = try getPdkCornerSet(pdk_id, allocator);
    defer corner_set.deinit();
    const corners = try corner_set.generateCorners(allocator);
    defer allocator.free(corners);

    for (corners) |corner| {
        var cfg = LibertyConfig.fromCorner(corner, pdk_id);
        // Write to separate file: cell_name_tt_025C_1v80.lib
        var path_buf: [512]u8 = undefined;
        const out_path = try std.fmt.bufPrint(&path_buf, "{s}_{s}.lib", .{ cell_name, corner.name });
        var file = try std.fs.cwd().createFile(out_path, .{});
        defer file.close();
        try generateLiberty(file.writer(), gds_path, spice_path, cell_name, cfg, allocator);
    }
}
```

### Phase 2: Error Handling — `src/liberty/spice_sim.zig`

**Current gaps:**
- ngspice not-found → crash
- Simulation convergence failure → bad values silently used
- Missing GDS/SPICE files → cryptic error

**Add:**
```zig
pub const SimError = error{
    NgspiceNotFound,
    SimulationConvergenceFailed,
    MeasureNotFound,
    InputFileNotFound,
    NgspiceExitCode,
};

fn checkNgspiceAvailable() SimError!void {
    const result = std.process.Child.run(.{
        .allocator = ...,
        .argv = &.{ "ngspice", "--version" },
    }) catch return SimError.NgspiceNotFound;
    if (result.term != .Exited or result.term.Exited != 0)
        return SimError.NgspiceNotFound;
}

fn parseMeasureWithFallback(output: []const u8, name: []const u8, fallback: f64) f64 {
    return parseMeasure(output, name) catch |err| {
        std.log.warn("measure {s} failed: {} — using fallback {d:.6}", .{name, err, fallback});
        return fallback;
    };
}
```

### Phase 3: Timing Sense Inference — `src/liberty/writer.zig`

**Current:** All timing arcs default to `non_unate`.

**Add netlist topology analysis:**
```zig
pub const TimingSense = enum {
    positive_unate,    // Output follows input direction (buffer)
    negative_unate,    // Output inverts input direction (inverter)
    non_unate,         // Both edges produce both output edges (XOR)
};

pub fn inferTimingSense(
    netlist: []const u8,  // SPICE text
    input_pin: []const u8,
    output_pin: []const u8,
) TimingSense {
    // Simple heuristic: count inversion stages
    // - Odd PMOS/NMOS series path = inverting = negative_unate
    // - Even = positive_unate
    // - Mixed = non_unate (safe default)
    // Full implementation: trace signal path through SPICE topology
    _ = netlist; _ = input_pin; _ = output_pin;
    return .non_unate; // Conservative safe default
}
```

**Better heuristic (SPICE topology tracing):**
```zig
// Parse .subckt, find series-connected device paths input→output
// Count PMOS stages in series path (each = inversion)
// Odd count = negative_unate, even = positive_unate
```

### Phase 4: CLI Entry Point — `python/liberty.py`

```python
#!/usr/bin/env python3
"""Liberty file production for Spout-characterized analog cells."""

import argparse
import subprocess
import sys
from pathlib import Path

def cmd_liberty_generate(args):
    from python.ffi import SpoutFFI
    ffi = SpoutFFI()

    if args.all_corners:
        result = ffi.liberty_generate_all_corners(
            gds_path=args.gds,
            spice_path=args.spice,
            cell_name=args.cell_name,
            pdk=args.pdk,
            output_dir=args.output_dir or ".",
        )
        print(f"Generated {result.num_files} Liberty files in {args.output_dir or '.'}")
    else:
        result = ffi.liberty_generate(
            gds_path=args.gds,
            spice_path=args.spice,
            cell_name=args.cell_name,
            pdk=args.pdk,
            corner=args.corner,
            output_path=args.output or f"{args.cell_name}_{args.corner}.lib",
        )
        print(f"Generated {result.output_path}")
        print(f"  Cell area: {result.area_um2:.3f} µm²")
        print(f"  Leakage: {result.leakage_nw:.3f} nW")
        if result.timing_arcs:
            print(f"  Timing arcs: {len(result.timing_arcs)}")

def main():
    parser = argparse.ArgumentParser(description="Spout Liberty file generator")
    subparsers = parser.add_subparsers(dest="command")

    gen = subparsers.add_parser("generate", help="Generate Liberty file")
    gen.add_argument("gds", help="Input GDS file")
    gen.add_argument("spice", help="Input SPICE netlist")
    gen.add_argument("--cell-name", "-c", required=True, help="Cell name")
    gen.add_argument("--pdk", default="sky130", choices=["sky130", "gf180", "ihp130"])
    gen.add_argument("--corner", default="tt_025C_1v80")
    gen.add_argument("--all-corners", "-a", action="store_true")
    gen.add_argument("--output", "-o", help="Output .lib path")
    gen.add_argument("--output-dir", help="Output directory (--all-corners mode)")
    gen.set_defaults(func=cmd_liberty_generate)

    args = parser.parse_args()
    if hasattr(args, "func"):
        args.func(args)
    else:
        parser.print_help()

if __name__ == "__main__":
    main()
```

### Phase 5: Python FFI Liberty Bindings

**Add to `python/ffi.py`:**
```python
def liberty_generate(
    self,
    gds_path: str,
    spice_path: str,
    cell_name: str,
    pdk: str = "sky130",
    corner: str = "tt_025C_1v80",
    output_path: str = "cell.lib",
) -> LibertyResult:
    # Calls spout_liberty_generate() via ctypes
    ...

def liberty_generate_all_corners(
    self,
    gds_path: str,
    spice_path: str,
    cell_name: str,
    pdk: str = "sky130",
    output_dir: str = ".",
) -> LibertyAllCornersResult:
    # Calls spout_liberty_generate_all_corners() via ctypes
    ...
```

**Add to `src/lib.zig`:**
```zig
export fn spout_liberty_generate(
    gds_path: [*:0]const u8,
    spice_path: [*:0]const u8,
    cell_name: [*:0]const u8,
    pdk_id: c_int,         // 0=sky130, 1=gf180, 2=ihp130
    corner_name: [*:0]const u8,
    output_path: [*:0]const u8,
) c_int;   // 0 = ok, negative = error code

export fn spout_liberty_generate_all_corners(
    gds_path: [*:0]const u8,
    spice_path: [*:0]const u8,
    cell_name: [*:0]const u8,
    pdk_id: c_int,
    output_dir: [*:0]const u8,
    out_num_files: *u32,
) c_int;
```

### Phase 6: Regression Tests

**Test fixture: `fixtures/liberty/inv_current_starved/`**
- `cell.spice` — simple current-starved inverter SPICE
- `cell.gds` — minimal GDS with just bounding box
- `reference_tt_025C_1v80.lib` — hand-verified reference Liberty file
- `test_liberty.zig` — Zig test comparing generated vs reference

```zig
// src/liberty/tests.zig
test "inverter liberty generation" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const cfg = LibertyConfig{
        .nom_voltage = 1.8,
        .nom_temperature = 25.0,
        .pdk = .sky130,
        .corner_name = "tt_025C_1v80",
    };

    var buf = std.ArrayList(u8).init(allocator);
    defer buf.deinit();

    try generateLiberty(
        buf.writer(),
        "fixtures/liberty/inv_current_starved/cell.gds",
        "fixtures/liberty/inv_current_starved/cell.spice",
        "inv_cs",
        cfg,
        allocator,
    );

    // Verify structure (not exact values — simulation varies)
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "library(") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "cell(inv_cs)") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "cell_rise(") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "cell_leakage_power") != null);
}
```

---

## Files Created/Modified

### New Files
| File | Purpose |
|------|---------|
| `src/import/gdsii.zig` | GDSII binary reader |
| `src/import/template.zig` | TemplateContext + TemplatePin structs |
| `python/liberty.py` | Liberty CLI entry point |
| `python/tinytapeout.py` | TinyTapeout-specific helpers |
| `fixtures/liberty/inv_current_starved/cell.spice` | Test fixture |
| `docs/plans/IMPL_GDS_TEMPLATE_AND_LIBERTY.md` | This document |

### Modified Files
| File | Changes |
|------|---------|
| `src/core/types.zig` | Add PlacementRegion, BlockedRegion types |
| `src/placer/sa.zig` | Add template bounds to SaConfig, enforce in move |
| `src/placer/cost.zig` | Add region penalty (hard bounds already in sa.zig) |
| `src/placer/tests.zig` | Add template bounds test |
| `src/router/grid.zig` | Mark blocked regions during grid init |
| `src/router/lib.zig` | Add BlockedRegion to AdvancedRoutingOptions |
| `src/export/gdsii.zig` | Add SREF writer, hierarchical export |
| `src/lib.zig` | Add C-ABI for template loading + liberty generation |
| `src/liberty/lib.zig` | Add multi-corner sweep function |
| `src/liberty/spice_sim.zig` | Add error handling, ngspice detection |
| `src/liberty/writer.zig` | Add timing sense inference |
| `build.zig` | Add import module, liberty tests |
| `python/main.py` | Add template_config param, liberty subcommand |
| `python/__init__.py` | Expose new modules |

---

## Agent Assignment

| Agent | Files | Description |
|-------|-------|-------------|
| **gds-reader** | `src/import/gdsii.zig`, `src/import/template.zig` | GDSII binary reader + TemplateContext |
| **gds-placer-router** | `src/placer/sa.zig`, `src/placer/cost.zig`, `src/router/grid.zig`, `src/router/lib.zig`, `src/core/types.zig` | Template constraint integration |
| **gds-export** | `src/export/gdsii.zig` | SREF writer + hierarchical export |
| **liberty-production** | `src/liberty/lib.zig`, `src/liberty/spice_sim.zig`, `src/liberty/writer.zig`, `python/liberty.py` | Liberty multi-corner + CLI |
| **integration** | `src/lib.zig`, `build.zig`, `python/main.py`, `python/__init__.py` | C-ABI + Python bindings |

---

## Dependencies

```
gds-reader (Phase 1-2) ──► gds-placer-router (Phase 3-4)  ──►
                         ──► gds-export (Phase 5)           ──► integration (Phase 6-7)
liberty-production (Phase 1-3+CLI) ──────────────────────────►
```

Agents gds-reader, gds-placer-router, gds-export, liberty-production can all run in parallel since:
- gds-reader creates new files only
- gds-placer-router touches different existing files than gds-export
- liberty-production is entirely separate subsystem

Integration agent runs after all others (touches lib.zig and Python bindings that reference all new types).
