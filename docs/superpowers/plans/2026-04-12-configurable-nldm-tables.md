# Configurable NxN NLDM Tables Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace hardcoded `NLDM_SIZE = 7` with runtime-configurable, asymmetric NLDM table dimensions backed by flat heap-allocated `[]f64`.

**Architecture:** `NldmTable` becomes a heap-allocated flat slice with `rows`/`cols` fields and `init`/`deinit`/`get`/`set` methods. `LibertyConfig` index arrays become slices defaulting to module-level 7-element const arrays. Writer generates template names dynamically from dimensions. All consumers updated to use table accessors and slice lengths.

**Tech Stack:** Zig, zig build test, nix develop shell

**Test command:** `nix develop --command zig build test --summary all`

---

### File Map

| File | Action | Responsibility |
|------|--------|----------------|
| `src/liberty/types.zig` | Modify | NldmTable struct, default index consts, LibertyConfig slice fields |
| `src/liberty/writer.zig` | Modify | Dynamic template names, table accessor usage |
| `src/liberty/spice_sim.zig` | Modify | Allocator plumbing, NldmTable.init in sweep |
| `src/liberty/lib.zig` | Modify | Table cleanup in deinit, comment updates |

---

### Task 1: NldmTable — New Struct and Unit Tests

**Files:**
- Modify: `src/liberty/types.zig:96-112` (NldmTable), `src/liberty/types.zig:220-224` (LibertyConfig indices)
- Tests in same file: `src/liberty/types.zig:272-292`

- [ ] **Step 1: Write failing test for new NldmTable.init**

Add to bottom of `src/liberty/types.zig` tests section:

```zig
test "NldmTable init zeroed" {
    const allocator = std.testing.allocator;
    const t = try NldmTable.init(allocator, 3, 4);
    defer t.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 3), t.rows);
    try std.testing.expectEqual(@as(usize, 4), t.cols);
    try std.testing.expectEqual(@as(usize, 12), t.values.len);
    try std.testing.expectEqual(@as(f64, 0.0), t.get(0, 0));
    try std.testing.expectEqual(@as(f64, 0.0), t.get(2, 3));
}

test "NldmTable scalar" {
    const allocator = std.testing.allocator;
    const t = try NldmTable.scalar(allocator, 5, 9, 0.05);
    defer t.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 5), t.rows);
    try std.testing.expectEqual(@as(usize, 9), t.cols);
    try std.testing.expectEqual(@as(f64, 0.05), t.get(0, 0));
    try std.testing.expectEqual(@as(f64, 0.05), t.get(4, 8));
    try std.testing.expectEqual(@as(f64, 0.05), t.get(2, 5));
}

test "NldmTable get/set" {
    const allocator = std.testing.allocator;
    var t = try NldmTable.init(allocator, 3, 4);
    defer t.deinit(allocator);
    t.set(1, 2, 42.0);
    try std.testing.expectEqual(@as(f64, 42.0), t.get(1, 2));
    try std.testing.expectEqual(@as(f64, 0.0), t.get(0, 0));
    t.set(2, 3, 99.0);
    try std.testing.expectEqual(@as(f64, 99.0), t.get(2, 3));
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `nix develop --command zig build test --summary all 2>&1 | tail -5`
Expected: compilation errors — `NldmTable.init` doesn't accept allocator yet.

- [ ] **Step 3: Implement new NldmTable struct**

Replace `NLDM_SIZE` constant and `NldmTable` struct in `src/liberty/types.zig` (lines 96-112). Remove `NLDM_SIZE`:

```zig
pub const NldmTable = struct {
    values: []f64,
    rows: usize,
    cols: usize,

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

- [ ] **Step 4: Update LibertyConfig index fields to slices**

Add module-level default arrays above `LibertyConfig` and change the fields:

```zig
pub const default_slew_indices = [_]f64{ 0.0100, 0.0230, 0.0531, 0.1233, 0.2830, 0.6497, 1.5000 };
pub const default_load_indices = [_]f64{ 0.0005, 0.0012, 0.0030, 0.0074, 0.0181, 0.0445, 0.1093 };
```

In `LibertyConfig`, replace:
```zig
    slew_indices: [NLDM_SIZE]f64 = .{ 0.0100, 0.0230, 0.0531, 0.1233, 0.2830, 0.6497, 1.5000 },
    load_indices: [NLDM_SIZE]f64 = .{ 0.0005, 0.0012, 0.0030, 0.0074, 0.0181, 0.0445, 0.1093 },
```
with:
```zig
    slew_indices: []const f64 = &default_slew_indices,
    load_indices: []const f64 = &default_load_indices,
```

- [ ] **Step 5: Update old NldmTable tests to new API**

Replace the old `"NldmTable scalar"` test (around line 272) with updated version using allocator:

```zig
test "NldmTable scalar 7x7 compat" {
    const allocator = std.testing.allocator;
    const t = try NldmTable.scalar(allocator, 7, 7, 0.05);
    defer t.deinit(allocator);
    try std.testing.expectEqual(@as(f64, 0.05), t.get(0, 0));
    try std.testing.expectEqual(@as(f64, 0.05), t.get(3, 4));
    try std.testing.expectEqual(@as(f64, 0.05), t.get(6, 6));
}
```

Remove old `"NldmTable scalar"` test.

- [ ] **Step 6: Run tests — types.zig tests should pass**

Run: `nix develop --command zig build test --summary all 2>&1 | tail -10`
Expected: types.zig tests pass. Other files may have compile errors (they still import `NLDM_SIZE` and use old NldmTable API). That's expected — fixed in later tasks.

- [ ] **Step 7: Commit**

```bash
git add src/liberty/types.zig
git commit -m "feat(liberty): runtime-configurable NldmTable with flat []f64 storage

Replace comptime NLDM_SIZE=7 fixed arrays with heap-allocated flat slice.
NldmTable now has init/deinit/get/set with rows/cols dimensions.
LibertyConfig index fields become slices with 7-element defaults."
```

---

### Task 2: Writer — Dynamic Template Names and Table Accessors

**Files:**
- Modify: `src/liberty/writer.zig`

- [ ] **Step 1: Write failing test for dynamic template name**

Add to bottom of `src/liberty/writer.zig` test section:

```zig
test "writeLiberty dynamic template name 11x11" {
    const alloc = std.testing.allocator;
    var buf = std.ArrayList(u8).init(alloc);
    defer buf.deinit();

    const slew_11 = [_]f64{ 0.005, 0.010, 0.020, 0.040, 0.080, 0.160, 0.320, 0.640, 1.000, 1.500, 2.000 };
    const load_11 = [_]f64{ 0.0002, 0.0005, 0.0012, 0.0030, 0.0074, 0.0181, 0.0445, 0.1000, 0.2000, 0.3500, 0.5000 };

    var config = LibertyConfig{};
    config.slew_indices = &slew_11;
    config.load_indices = &load_11;

    const cell = LibertyCell{
        .name = "test_11x11",
        .area = 1.0,
        .leakage_power = 0.0,
        .pg_pins = &.{},
        .pins = &.{},
    };

    try writeLiberty(buf.writer(), &cell, config);
    const output = buf.items;

    try std.testing.expect(std.mem.indexOf(u8, output, "lu_table_template(delay_template_11x11)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "lu_table_template(power_template_11x11)") != null);
    // Must NOT contain 7x7
    try std.testing.expect(std.mem.indexOf(u8, output, "7x7") == null);
}

test "writeLiberty asymmetric template name 5x9" {
    const alloc = std.testing.allocator;
    var buf = std.ArrayList(u8).init(alloc);
    defer buf.deinit();

    const slew_5 = [_]f64{ 0.01, 0.05, 0.10, 0.50, 1.00 };
    const load_9 = [_]f64{ 0.0005, 0.001, 0.002, 0.005, 0.01, 0.02, 0.05, 0.08, 0.10 };

    var config = LibertyConfig{};
    config.slew_indices = &slew_5;
    config.load_indices = &load_9;

    const cell = LibertyCell{
        .name = "test_asym",
        .area = 1.0,
        .leakage_power = 0.0,
        .pg_pins = &.{},
        .pins = &.{},
    };

    try writeLiberty(buf.writer(), &cell, config);
    const output = buf.items;

    try std.testing.expect(std.mem.indexOf(u8, output, "lu_table_template(delay_template_5x9)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "lu_table_template(power_template_5x9)") != null);
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `nix develop --command zig build test --summary all 2>&1 | tail -10`
Expected: compile errors or assertion failures — writer still hardcodes `7x7`.

- [ ] **Step 3: Update writer.zig imports and writeLiberty**

Remove `NLDM_SIZE` import line. In `writeLiberty`, replace hardcoded template name calls:

```zig
    // NLDM table templates
    const slew_len = config.slew_indices.len;
    const load_len = config.load_indices.len;
    try writeTableTemplate(out, "delay_template_", slew_len, load_len, config.slew_indices, config.load_indices);
    try writeTableTemplate(out, "power_template_", slew_len, load_len, config.slew_indices, config.load_indices);
```

Update `writeTableTemplate` signature:

```zig
fn writeTableTemplate(out: anytype, prefix: []const u8, slew_len: usize, load_len: usize, index_1: []const f64, index_2: []const f64) !void {
    try out.print("  lu_table_template({s}{d}x{d}) {{\n", .{ prefix, slew_len, load_len });
    try out.writeAll("    variable_1 : input_net_transition;\n");
    try out.writeAll("    variable_2 : total_output_net_capacitance;\n");
    try writeIndexLine(out, "    index_1", index_1);
    try writeIndexLine(out, "    index_2", index_2);
    try out.writeAll("  }\n\n");
}
```

- [ ] **Step 4: Update writeTimingArc to accept dynamic template name**

Change `writeTimingArc` signature to accept delay template name:

```zig
fn writeTimingArc(out: anytype, arc: *const TimingArc, delay_tpl: []const u8) !void {
    try out.writeAll("      timing() {\n");
    try out.print("        related_pin : \"{s}\";\n", .{arc.related_pin});
    if (arc.related_power_pin) |pp| {
        try out.print("        related_power_pin : \"{s}\";\n", .{pp});
    }
    if (arc.related_ground_pin) |gp| {
        try out.print("        related_ground_pin : \"{s}\";\n", .{gp});
    }
    try out.print("        timing_sense : {s};\n", .{arc.timing_sense.asString()});
    try out.print("        timing_type : {s};\n", .{arc.timing_type.asString()});

    try writeNldmBlock(out, "cell_rise", delay_tpl, &arc.cell_rise);
    try writeNldmBlock(out, "cell_fall", delay_tpl, &arc.cell_fall);
    try writeNldmBlock(out, "rise_transition", delay_tpl, &arc.rise_transition);
    try writeNldmBlock(out, "fall_transition", delay_tpl, &arc.fall_transition);

    try out.writeAll("      }\n");
}
```

- [ ] **Step 5: Update writeInternalPower to accept dynamic template name**

```zig
fn writeInternalPower(out: anytype, pwr: *const InternalPower, power_tpl: []const u8) !void {
    try out.writeAll("      internal_power() {\n");
    try out.print("        related_pin : \"{s}\";\n", .{pwr.related_pin});
    if (pwr.related_pg_pin) |pg| {
        try out.print("        related_pg_pin : \"{s}\";\n", .{pg});
    }

    try writeNldmBlock(out, "rise_power", power_tpl, &pwr.rise_power);
    try writeNldmBlock(out, "fall_power", power_tpl, &pwr.fall_power);

    try out.writeAll("      }\n");
}
```

- [ ] **Step 6: Update writePin to generate and pass template names**

`writePin` needs config to build template names. Change signature and generate names:

```zig
fn writePin(out: anytype, pin: *const LibertyPin, config: LibertyConfig) !void {
    try out.print("    pin({s}) {{\n", .{pin.name});
    try out.print("      direction : {s};\n", .{pin.direction.asString()});

    if (pin.capacitance > 0.0) {
        try out.print("      capacitance : {d:.6};\n", .{pin.capacitance});
    }
    if (pin.max_capacitance > 0.0) {
        try out.print("      max_capacitance : {d:.6};\n", .{pin.max_capacitance});
    }

    // Build template names from config dimensions
    var delay_buf: [64]u8 = undefined;
    const delay_tpl = std.fmt.bufPrint(&delay_buf, "delay_template_{d}x{d}", .{ config.slew_indices.len, config.load_indices.len }) catch "delay_template_7x7";
    var power_buf: [64]u8 = undefined;
    const power_tpl = std.fmt.bufPrint(&power_buf, "power_template_{d}x{d}", .{ config.slew_indices.len, config.load_indices.len }) catch "power_template_7x7";

    for (pin.timing_arcs) |arc| {
        try writeTimingArc(out, &arc, delay_tpl);
    }
    for (pin.internal_power) |pwr| {
        try writeInternalPower(out, &pwr, power_tpl);
    }

    try out.writeAll("    }\n");
}
```

Update the call in `writeLiberty`:

```zig
    for (cell.pins) |pin| {
        try writePin(out, &pin, config);
    }
```

- [ ] **Step 7: Update writeNldmBlock to use table accessors**

```zig
fn writeNldmBlock(out: anytype, name: []const u8, template: []const u8, table: *const NldmTable) !void {
    try out.print("        {s}({s}) {{\n", .{ name, template });
    try out.writeAll("          values (\n");
    for (0..table.rows) |i| {
        try out.writeAll("            \"");
        for (0..table.cols) |j| {
            if (j > 0) try out.writeAll(", ");
            try out.print("{d:.6}", .{table.get(i, j)});
        }
        if (i < table.rows - 1) {
            try out.writeAll("\",\n");
        } else {
            try out.writeAll("\"\n");
        }
    }
    try out.writeAll("          );\n");
    try out.writeAll("        }\n");
}
```

- [ ] **Step 8: Update existing writer tests to use allocator-based NldmTable**

In `"writeLiberty minimal cell"` test, replace all `NldmTable.scalar(val)` with `try NldmTable.scalar(alloc, 7, 7, val)`. Add `const alloc = std.testing.allocator;` at top. Add defer deinit for each table. The timing arcs and internal power are constructed inline — they need to be built with allocated tables:

```zig
test "writeLiberty minimal cell" {
    const PgPinType = types.PgPinType;
    const alloc = std.testing.allocator;
    var buf = std.ArrayList(u8).init(alloc);
    defer buf.deinit();

    const cr = try NldmTable.scalar(alloc, 7, 7, 0.05);
    defer cr.deinit(alloc);
    const cf = try NldmTable.scalar(alloc, 7, 7, 0.04);
    defer cf.deinit(alloc);
    const rt = try NldmTable.scalar(alloc, 7, 7, 0.03);
    defer rt.deinit(alloc);
    const ft = try NldmTable.scalar(alloc, 7, 7, 0.02);
    defer ft.deinit(alloc);
    const rp = try NldmTable.scalar(alloc, 7, 7, 0.001);
    defer rp.deinit(alloc);
    const fp = try NldmTable.scalar(alloc, 7, 7, 0.002);
    defer fp.deinit(alloc);

    const cell = LibertyCell{
        .name = "test_inv",
        .area = 1.234,
        .leakage_power = 0.567,
        .pg_pins = &.{
            .{ .name = "VPWR", .pg_type = PgPinType.primary_power, .voltage_name = "VDD" },
            .{ .name = "VGND", .pg_type = PgPinType.primary_ground, .voltage_name = "VSS" },
        },
        .pins = &.{
            LibertyPin{
                .name = "A",
                .direction = .input,
                .capacitance = 0.002,
                .max_capacitance = 0.0,
                .timing_arcs = &.{},
                .internal_power = &.{},
            },
            LibertyPin{
                .name = "Y",
                .direction = .output,
                .capacitance = 0.0,
                .max_capacitance = 0.1,
                .timing_arcs = &.{
                    TimingArc{
                        .related_pin = "A",
                        .timing_sense = .negative_unate,
                        .timing_type = .combinational,
                        .cell_rise = cr,
                        .cell_fall = cf,
                        .rise_transition = rt,
                        .fall_transition = ft,
                    },
                },
                .internal_power = &.{
                    InternalPower{
                        .related_pin = "A",
                        .rise_power = rp,
                        .fall_power = fp,
                    },
                },
            },
        },
    };

    const config = LibertyConfig{};
    try writeLiberty(buf.writer(), &cell, config);

    const output = buf.items;

    try std.testing.expect(std.mem.indexOf(u8, output, "library(spout_analog)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "technology (cmos)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "nom_voltage : 1.800") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "voltage_map(VDD, 1.80)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "voltage_map(VSS, 0.00)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "lu_table_template(delay_template_7x7)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "input_net_transition") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "total_output_net_capacitance") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "pg_pin(VPWR)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "pg_type : primary_power") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "voltage_name : VDD") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "pg_pin(VGND)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "pg_type : primary_ground") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "cell(test_inv)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "area : 1.234") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "pin(A)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "pin(Y)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "related_pin : \"A\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "timing_sense : negative_unate") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "cell_rise(delay_template_7x7)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "rise_power(power_template_7x7)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "values (") != null);
}
```

Similarly update `"writeLiberty pg_pin only cell"` test (no NldmTable changes needed there — it has no timing arcs).

- [ ] **Step 9: Run tests to verify writer tests pass**

Run: `nix develop --command zig build test --summary all 2>&1 | tail -10`
Expected: writer tests pass including new 11x11 and 5x9 template name tests. spice_sim/lib.zig may still have compile errors.

- [ ] **Step 10: Commit**

```bash
git add src/liberty/writer.zig
git commit -m "feat(liberty): writer emits dynamic NxM template names

Template names derived from config.slew_indices.len x config.load_indices.len.
writeNldmBlock uses table.get()/rows/cols instead of fixed NLDM_SIZE loops."
```

---

### Task 3: spice_sim.zig — Allocator Plumbing for Table Construction

**Files:**
- Modify: `src/liberty/spice_sim.zig:29` (remove NLDM_SIZE import), `src/liberty/spice_sim.zig:280` (max_capacitance), `src/liberty/spice_sim.zig:399-429` (measureTimingArc)

- [ ] **Step 1: Remove NLDM_SIZE import**

In `src/liberty/spice_sim.zig`, remove line 29:
```zig
const NLDM_SIZE = types.NLDM_SIZE;
```

- [ ] **Step 2: Update max_capacitance in characterizePins**

Replace line 280:
```zig
.max_capacitance = self.config.load_indices[NLDM_SIZE - 1],
```
with:
```zig
.max_capacitance = self.config.load_indices[self.config.load_indices.len - 1],
```

- [ ] **Step 3: Update measureTimingArc to allocate tables**

Change `measureTimingArc` signature to accept allocator and return errors:

```zig
fn measureTimingArc(self: *SimContext, allocator: std.mem.Allocator, input_pin: []const u8, output_pin: []const u8) !TimingResult {
    const slew_count = self.config.slew_indices.len;
    const load_count = self.config.load_indices.len;

    var arc = TimingArc{
        .related_pin = input_pin,
        .timing_sense = .non_unate,
        .timing_type = .combinational,
        .cell_rise = try NldmTable.init(allocator, slew_count, load_count),
        .cell_fall = try NldmTable.init(allocator, slew_count, load_count),
        .rise_transition = try NldmTable.init(allocator, slew_count, load_count),
        .fall_transition = try NldmTable.init(allocator, slew_count, load_count),
    };
    errdefer {
        arc.cell_rise.deinit(allocator);
        arc.cell_fall.deinit(allocator);
        arc.rise_transition.deinit(allocator);
        arc.fall_transition.deinit(allocator);
    }

    var pwr = InternalPower{
        .related_pin = input_pin,
        .rise_power = try NldmTable.init(allocator, slew_count, load_count),
        .fall_power = try NldmTable.init(allocator, slew_count, load_count),
    };
    errdefer {
        pwr.rise_power.deinit(allocator);
        pwr.fall_power.deinit(allocator);
    }

    for (self.config.slew_indices, 0..) |slew, si| {
        for (self.config.load_indices, 0..) |load, li| {
            const pt = try self.measureSinglePoint(input_pin, output_pin, slew, load);
            arc.cell_rise.set(si, li, pt.tpd_rise_ns);
            arc.cell_fall.set(si, li, pt.tpd_fall_ns);
            arc.rise_transition.set(si, li, pt.t_rise_ns);
            arc.fall_transition.set(si, li, pt.t_fall_ns);
            pwr.rise_power.set(si, li, pt.rise_pj);
            pwr.fall_power.set(si, li, pt.fall_pj);
        }
    }

    return .{ .arc = arc, .power = pwr };
}
```

Note: `arc.cell_rise.set(si, li, val)` — `set` takes `*NldmTable` but `arc` is `var` so field access through it is mutable.

- [ ] **Step 4: Update characterizePins call site**

In `characterizePins`, update the call from:
```zig
var result = try self.measureTimingArc(inp, outp);
```
to:
```zig
var result = try self.measureTimingArc(allocator, inp, outp);
```

- [ ] **Step 5: Run tests**

Run: `nix develop --command zig build test --summary all 2>&1 | tail -10`
Expected: spice_sim compiles. Existing spice_sim unit tests pass (they don't exercise measureTimingArc directly — that needs ngspice). lib.zig may still have issues.

- [ ] **Step 6: Commit**

```bash
git add src/liberty/spice_sim.zig
git commit -m "feat(liberty): spice_sim allocates NldmTable via allocator

measureTimingArc takes allocator, creates tables with dimensions from
config.slew_indices.len x config.load_indices.len. Proper errdefer cleanup."
```

---

### Task 4: lib.zig — Table Cleanup and Integration Test Update

**Files:**
- Modify: `src/liberty/lib.zig:75-84` (cleanup), `src/liberty/lib.zig:137-231` (integration test)

- [ ] **Step 1: Update table cleanup in generateLiberty**

Replace the cleanup block (lines 77-84):

```zig
    defer {
        for (char_result.pins) |p| {
            for (p.timing_arcs) |arc| {
                arc.cell_rise.deinit(allocator);
                arc.cell_fall.deinit(allocator);
                arc.rise_transition.deinit(allocator);
                arc.fall_transition.deinit(allocator);
            }
            for (p.internal_power) |pwr| {
                pwr.rise_power.deinit(allocator);
                pwr.fall_power.deinit(allocator);
            }
            allocator.free(p.timing_arcs);
            allocator.free(p.internal_power);
        }
        allocator.free(char_result.pins);
        allocator.free(char_result.pg_pins);
    }
```

- [ ] **Step 2: Update comment**

Change line 75 from:
```zig
    // 4. Run transient sims (7×7 NLDM sweep) for each timing arc
```
to:
```zig
    // 4. Run transient sims (NxM NLDM sweep) for each timing arc
```

- [ ] **Step 3: Update integration test to use allocator-based NldmTable**

Replace the integration test body to allocate tables properly:

```zig
test "generateLiberty integration: synthetic cell produces valid Liberty" {
    const alloc = std.testing.allocator;
    const NldmTable = types.NldmTable;
    const PgPin = types.PgPin;
    var buf = std.ArrayList(u8).init(alloc);
    defer buf.deinit();

    const cr = try NldmTable.scalar(alloc, 7, 7, 0.045);
    defer cr.deinit(alloc);
    const cf = try NldmTable.scalar(alloc, 7, 7, 0.038);
    defer cf.deinit(alloc);
    const rt = try NldmTable.scalar(alloc, 7, 7, 0.032);
    defer rt.deinit(alloc);
    const ft = try NldmTable.scalar(alloc, 7, 7, 0.028);
    defer ft.deinit(alloc);
    const rp = try NldmTable.scalar(alloc, 7, 7, 0.0012);
    defer rp.deinit(alloc);
    const fp = try NldmTable.scalar(alloc, 7, 7, 0.0015);
    defer fp.deinit(alloc);

    const timing_arcs = try alloc.alloc(TimingArc, 1);
    defer alloc.free(timing_arcs);
    timing_arcs[0] = .{
        .related_pin = "INP",
        .timing_sense = .negative_unate,
        .timing_type = .combinational,
        .cell_rise = cr,
        .cell_fall = cf,
        .rise_transition = rt,
        .fall_transition = ft,
    };

    const int_power = try alloc.alloc(InternalPower, 1);
    defer alloc.free(int_power);
    int_power[0] = .{
        .related_pin = "INP",
        .rise_power = rp,
        .fall_power = fp,
    };

    const pg_pins = try alloc.alloc(PgPin, 2);
    defer alloc.free(pg_pins);
    pg_pins[0] = .{ .name = "VDD", .pg_type = .primary_power, .voltage_name = "VDD" };
    pg_pins[1] = .{ .name = "VSS", .pg_type = .primary_ground, .voltage_name = "VSS" };

    const pins = try alloc.alloc(LibertyPin, 2);
    defer alloc.free(pins);
    pins[0] = .{ .name = "INP", .direction = .input, .capacitance = 0.002, .max_capacitance = 0, .timing_arcs = &.{}, .internal_power = &.{} };
    pins[1] = .{ .name = "OUT", .direction = .output, .capacitance = 0, .max_capacitance = 0.1, .timing_arcs = timing_arcs, .internal_power = int_power };

    const cell = LibertyCell{
        .name = "current_mirror",
        .area = 125.6,
        .leakage_power = 0.85,
        .pins = pins,
        .pg_pins = pg_pins,
    };

    const config = LibertyConfig{};
    try writer.writeLiberty(buf.writer(), &cell, config);

    const output = buf.items;
    const testing = std.testing;

    try testing.expect(std.mem.indexOf(u8, output, "library(spout_analog)") != null);
    try testing.expect(std.mem.indexOf(u8, output, "technology (cmos)") != null);
    try testing.expect(std.mem.indexOf(u8, output, "cell(current_mirror)") != null);
    try testing.expect(std.mem.indexOf(u8, output, "area : 125.6") != null);
    try testing.expect(std.mem.indexOf(u8, output, "cell_leakage_power") != null);
    try testing.expect(std.mem.indexOf(u8, output, "voltage_map(VDD, 1.80)") != null);
    try testing.expect(std.mem.indexOf(u8, output, "voltage_map(VSS, 0.00)") != null);
    try testing.expect(std.mem.indexOf(u8, output, "lu_table_template(delay_template_7x7)") != null);
    try testing.expect(std.mem.indexOf(u8, output, "lu_table_template(power_template_7x7)") != null);
    try testing.expect(std.mem.indexOf(u8, output, "pg_pin(VDD)") != null);
    try testing.expect(std.mem.indexOf(u8, output, "pg_type : primary_power") != null);
    try testing.expect(std.mem.indexOf(u8, output, "pg_pin(VSS)") != null);
    try testing.expect(std.mem.indexOf(u8, output, "pg_type : primary_ground") != null);
    try testing.expect(std.mem.indexOf(u8, output, "pin(INP)") != null);
    try testing.expect(std.mem.indexOf(u8, output, "pin(OUT)") != null);
    try testing.expect(std.mem.indexOf(u8, output, "timing()") != null);
    try testing.expect(std.mem.indexOf(u8, output, "related_pin : \"INP\"") != null);
    try testing.expect(std.mem.indexOf(u8, output, "cell_rise(delay_template_7x7)") != null);
    try testing.expect(std.mem.indexOf(u8, output, "cell_fall(delay_template_7x7)") != null);
    try testing.expect(std.mem.indexOf(u8, output, "rise_transition(delay_template_7x7)") != null);
    try testing.expect(std.mem.indexOf(u8, output, "fall_transition(delay_template_7x7)") != null);
    try testing.expect(std.mem.indexOf(u8, output, "internal_power()") != null);
    try testing.expect(std.mem.indexOf(u8, output, "rise_power(power_template_7x7)") != null);
    try testing.expect(std.mem.indexOf(u8, output, "fall_power(power_template_7x7)") != null);
    try testing.expect(std.mem.indexOf(u8, output, "nom_voltage : 1.800") != null);
    try testing.expect(std.mem.indexOf(u8, output, "nom_temperature : 25.0") != null);
}
```

- [ ] **Step 4: Run full test suite**

Run: `nix develop --command zig build test --summary all 2>&1 | tail -10`
Expected: all 598+ tests pass. No memory leaks (testing.allocator catches those).

- [ ] **Step 5: Commit**

```bash
git add src/liberty/lib.zig
git commit -m "feat(liberty): table deinit in generateLiberty cleanup

Each NldmTable in TimingArc/InternalPower freed via deinit(allocator).
Integration test updated to allocator-based NldmTable API."
```

---

### Task 5: Update TODO.md — Mark NLDM Item Complete

**Files:**
- Modify: `src/liberty/TODO.md`

- [ ] **Step 1: Move NLDM section to completed**

In `src/liberty/TODO.md`, remove the "NLDM Table Size: Configurable NxN" section (lines 3-19) and add to the Completed list:

```markdown
- [x] NLDM table size: configurable NxM (asymmetric) with flat heap-allocated storage
```

- [ ] **Step 2: Commit**

```bash
git add src/liberty/TODO.md
git commit -m "docs: mark configurable NLDM tables as complete"
```
