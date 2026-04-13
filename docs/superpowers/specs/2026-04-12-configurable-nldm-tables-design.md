# Configurable NxN NLDM Tables

**Date:** 2026-04-12
**Status:** Approved
**Scope:** `src/liberty/types.zig`, `writer.zig`, `spice_sim.zig`, `lib.zig`

## Goal

Replace the hardcoded `NLDM_SIZE = 7` comptime constant with runtime-configurable, asymmetric NLDM table dimensions. Enables 7x7 (standard), 11x11 (high accuracy), 15x15 (max density), and asymmetric sizes like 7x11 (fewer slew points, more load points).

## Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Symmetric vs asymmetric | Asymmetric (separate rows/cols) | Slew expensive to sweep, load cheap. Config already has separate slew/load indices. |
| Allocation strategy | Flat `[]f64` + dimensions | Single alloc per table, cache-friendly, no nested slices. Index as `values[row * cols + col]`. |
| Default size / backward compat | Module-level const arrays, slice defaults | `LibertyConfig{}` keeps working with 7x7. No allocator needed for config. |
| Table ownership | NldmTable owns its memory | `init(allocator)` / `deinit(allocator)`. Matches existing manual cleanup in lib.zig. |

## Changes

### types.zig

Remove `NLDM_SIZE` constant.

Replace `NldmTable`:

```zig
pub const NldmTable = struct {
    values: []f64,   // flat row-major, length = rows * cols
    rows: usize,     // slew dimension
    cols: usize,     // load dimension

    pub fn init(allocator: std.mem.Allocator, rows: usize, cols: usize) !NldmTable {
        const values = try allocator.alloc(f64, rows * cols);
        @memset(values, 0.0);
        return .{ .values = values, .rows = rows, .cols = cols };
    }

    pub fn scalar(allocator: std.mem.Allocator, rows: usize, cols: usize, val: f64) !NldmTable {
        const values = try allocator.alloc(f64, rows * cols);
        @memset(values, val);
        return .{ .values = values, .rows = rows, .cols = cols };
    }

    pub fn deinit(self: NldmTable, allocator: std.mem.Allocator) void {
        allocator.free(self.values);
    }

    pub fn get(self: NldmTable, row: usize, col: usize) f64 {
        return self.values[row * self.cols + col];
    }

    pub fn set(self: *NldmTable, row: usize, col: usize, val: f64) void {
        self.values[row * self.cols + col] = val;
    }
};
```

Replace fixed-size index arrays with slices defaulting to module-level consts:

```zig
pub const default_slew_indices = [_]f64{ 0.0100, 0.0230, 0.0531, 0.1233, 0.2830, 0.6497, 1.5000 };
pub const default_load_indices = [_]f64{ 0.0005, 0.0012, 0.0030, 0.0074, 0.0181, 0.0445, 0.1093 };

pub const LibertyConfig = struct {
    // ... existing fields unchanged ...
    slew_indices: []const f64 = &default_slew_indices,
    load_indices: []const f64 = &default_load_indices,
};
```

### writer.zig

- Remove `NLDM_SIZE` import.
- `writeLiberty`: generate template names dynamically from `config.slew_indices.len` and `config.load_indices.len`:
  - `delay_template_{slew_len}x{load_len}`
  - `power_template_{slew_len}x{load_len}`
- `writeNldmBlock`: accept table dimensions from `table.rows`/`table.cols`, use `table.get(i, j)` instead of `table.values[i][j]`.
- `writeTableTemplate`: already takes slices, no change needed.
- Template name passed through to `writeTimingArc` and `writeInternalPower` (or computed there from config).

### spice_sim.zig

- Remove `NLDM_SIZE` import.
- `measureTimingArc`: use `NldmTable.init(allocator, slew_count, load_count)` for each table, then `table.set(si, li, val)` in the sweep loop. Needs allocator parameter added.
- `characterizePins`: pass allocator through to `measureTimingArc`.
- `max_capacitance`: use `self.config.load_indices[self.config.load_indices.len - 1]`.
- Loop bounds already derive from `self.config.slew_indices` / `self.config.load_indices` iteration.

### lib.zig

- Cleanup loop: add `table.deinit(allocator)` for each NldmTable in each `TimingArc` (4 tables) and `InternalPower` (2 tables).
- Update comment from "7x7 NLDM sweep" to "NxM NLDM sweep".

## Tests

- **Existing tests**: update `NldmTable.scalar(val)` calls to `NldmTable.scalar(allocator, 7, 7, val)`. Add corresponding `deinit` calls (or use `testing.allocator` which detects leaks).
- **Asymmetric table test**: create 5x9 table, verify `get`/`set` at boundary indices, verify dimensions.
- **Writer template name test**: config with 11x11 indices produces `delay_template_11x11` in output.
- **Writer asymmetric test**: config with 7x11 indices produces `delay_template_7x11`.

## Not In Scope

- New breakpoint values for larger tables (log-spacing, extended ranges). Config already accepts arbitrary slices; users provide their own.
- Volare PDK corner support (separate TODO item).
- ADC validation (separate TODO item).
