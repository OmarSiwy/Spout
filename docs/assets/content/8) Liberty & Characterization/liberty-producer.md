# Liberty File Producer

The Liberty file producer is the subsystem responsible for generating `.lib` files — the standard format that synthesis and static timing analysis tools (OpenSTA, Yosys, OpenROAD) use to understand the timing, power, and area characteristics of cells. Spout generates Liberty files directly from GDS geometry and SPICE netlists, characterizing analog and mixed-signal cells through ngspice simulation.

---

## What Is the Liberty (.lib) Format?

Liberty is a text-based format originally defined by Synopsys (Liberty Reference Manual). It describes a library of cells — their timing arcs, power consumption, and pin capacitances — as a function of operating conditions. Every commercial and open-source digital synthesis and STA tool understands Liberty.

### File Structure Overview

A Liberty file is organized as a tree of named groups with attributes. The top-level group is `library()`, which contains one or more `cell()` groups. Each cell contains `pin()` groups, and each pin contains `timing()` and `internal_power()` groups with NLDM lookup tables.

```
library(spout_analog) {
  technology (cmos);
  delay_model : table_lookup;
  time_unit : "1ns";
  voltage_unit : "1V";
  current_unit : "1uA";
  pulling_resistance_unit : "1kohm";
  capacitive_load_unit(1, pf);
  leakage_power_unit : "1nW";
  nom_process : 1;
  nom_voltage : 1.800;
  nom_temperature : 25.0;

  voltage_map(VDD, 1.80);
  voltage_map(VSS, 0.00);

  lu_table_template(delay_template_7x7) {
    variable_1 : input_net_transition;
    variable_2 : total_output_net_capacitance;
    index_1 ("0.0100, 0.0230, 0.0531, 0.1233, 0.2830, 0.6497, 1.5000");
    index_2 ("0.0005, 0.0012, 0.0030, 0.0074, 0.0181, 0.0445, 0.1093");
  }

  lu_table_template(power_template_7x7) { ... }

  operating_conditions("typical") {
    process : 1;
    voltage : 1.800;
    temperature : 25.0;
  }
  default_operating_conditions : "typical";

  cell(current_mirror) {
    area : 125.600000;
    cell_leakage_power : 0.850000;

    pg_pin(VDD) {
      pg_type : primary_power;
      voltage_name : VDD;
    }
    pg_pin(VSS) {
      pg_type : primary_ground;
      voltage_name : VSS;
    }

    pin(INP) {
      direction : input;
      capacitance : 0.002000;
    }

    pin(OUT) {
      direction : output;
      max_capacitance : 0.100000;
      timing() {
        related_pin : "INP";
        timing_sense : negative_unate;
        timing_type : combinational;
        cell_rise(delay_template_7x7) {
          values (
            "0.045000, 0.045000, ...",
            ...
          );
        }
        cell_fall(delay_template_7x7) { ... }
        rise_transition(delay_template_7x7) { ... }
        fall_transition(delay_template_7x7) { ... }
      }
      internal_power() {
        related_pin : "INP";
        rise_power(power_template_7x7) { ... }
        fall_power(power_template_7x7) { ... }
      }
    }
  }
}
```

### Library Header Fields

| Field | Example Value | Units | Meaning |
|---|---|---|---|
| `technology` | `cmos` | — | Process technology family |
| `delay_model` | `table_lookup` | — | NLDM table-lookup model |
| `time_unit` | `"1ns"` | — | All time values are in nanoseconds |
| `voltage_unit` | `"1V"` | — | All voltage values in volts |
| `current_unit` | `"1uA"` | — | Current values in microamps |
| `pulling_resistance_unit` | `"1kohm"` | — | Pull-up/pull-down resistance unit |
| `capacitive_load_unit` | `1, pf` | — | Load capacitance in picofarads |
| `leakage_power_unit` | `"1nW"` | — | Leakage power values in nanowatts |
| `nom_process` | `1` | — | Process corner factor (1 = typical) |
| `nom_voltage` | `1.800` | V | Nominal supply voltage |
| `nom_temperature` | `25.0` | °C | Nominal operating temperature |
| `voltage_map(VDD, 1.80)` | — | V | Maps supply net name to voltage |
| `voltage_map(VSS, 0.00)` | — | V | Maps ground net name to 0 V |

### NLDM Table Templates

Before any cell data, the library declares `lu_table_template` groups that define the axis variables and index breakpoints shared by all NLDM tables. Spout generates two templates:

- `delay_template_NxM`: used for `cell_rise`, `cell_fall`, `rise_transition`, `fall_transition`
- `power_template_NxM`: used for `rise_power`, `fall_power`

Both templates use:
- `variable_1 : input_net_transition` — the input slew rate (ns)
- `variable_2 : total_output_net_capacitance` — the output load capacitance (pF)
- `index_1` — the slew breakpoints (ns), a quoted comma-separated list
- `index_2` — the load breakpoints (pF), a quoted comma-separated list

The template names encode the table dimensions: `delay_template_7x7` for a 7-slew × 7-load table.

### Cell Block Fields

| Field | Example Value | Units | Meaning |
|---|---|---|---|
| `area` | `125.600000` | µm² | Bounding-box area from GDS |
| `cell_leakage_power` | `0.850000` | nW | DC quiescent power from ngspice |

### pg_pin Groups

Power/ground pins are declared as `pg_pin()` groups rather than regular `pin()` groups. Fields:

| Field | Values | Meaning |
|---|---|---|
| `pg_type` | `primary_power`, `primary_ground`, `nwell`, `pwell` | Supply role |
| `voltage_name` | `VDD`, `VSS` | Maps to `voltage_map` entry |

### Signal pin Block Fields

| Field | Example Value | Units | Meaning |
|---|---|---|---|
| `direction` | `input`, `output`, `inout`, `internal` | — | Pin direction |
| `capacitance` | `0.002000` | pF | Input pin capacitance (measured via AC analysis) |
| `max_capacitance` | `0.100000` | pF | Maximum load on output pin |

### timing() Groups

Each output pin carries one `timing()` group per input pin driving it. Fields:

| Field | Example Value | Meaning |
|---|---|---|
| `related_pin` | `"INP"` | The input pin driving this arc |
| `related_power_pin` | `"VPWR"` | pg_pin supplying power (optional) |
| `related_ground_pin` | `"VGND"` | pg_pin supplying ground (optional) |
| `timing_sense` | `positive_unate`, `negative_unate`, `non_unate` | Unateness of the arc |
| `timing_type` | `combinational`, `rising_edge`, `falling_edge`, `setup_rising`, `setup_falling`, `hold_rising`, `hold_falling` | Arc type |

Each `timing()` group contains four NLDM tables: `cell_rise`, `cell_fall`, `rise_transition`, `fall_transition`.

### NLDM Table Values

An NLDM table references a template by name and supplies the `values` array:

```
cell_rise(delay_template_7x7) {
  values (
    "0.045000, 0.045000, 0.045000, 0.045000, 0.045000, 0.045000, 0.045000",
    "0.045000, 0.045000, ...",
    ...
  );
}
```

The values are in row-major order: each row corresponds to one `index_1` (slew) value, and each column corresponds to one `index_2` (load) value. Units are nanoseconds for timing tables, picojoules for power tables.

### internal_power() Groups

Each output pin may also carry `internal_power()` groups with `rise_power` and `fall_power` tables (picojoules).

---

## Architecture of the Liberty Subsystem

The Liberty subsystem lives in `src/liberty/` and consists of five files:

| File | Role |
|---|---|
| `lib.zig` | Public API: `generateLiberty`, `generateLibertyAllCorners`, `applyCorner` |
| `types.zig` | Data model: all structs and enums |
| `writer.zig` | Text serializer: converts structs to `.lib` text |
| `spice_sim.zig` | ngspice harness: runs simulations to populate table values |
| `gds_area.zig` | GDSII parser: extracts bounding-box area |
| `pdk.zig` | PDK corner definitions: sky130, gf180mcu |

---

## Data Model (`types.zig`)

### `LibertyConfig`

All characterization parameters, with defaults matching sky130 typical corner:

| Field | Type | Default | Meaning |
|---|---|---|---|
| `nom_voltage` | `f64` | `1.8` | Supply voltage (V) |
| `nom_temperature` | `f64` | `25.0` | Temperature (°C) |
| `nom_process` | `[]const u8` | `"typical"` | Process corner name |
| `time_unit` | `[]const u8` | `"1ns"` | Liberty time unit string |
| `voltage_unit` | `[]const u8` | `"1V"` | Liberty voltage unit string |
| `current_unit` | `[]const u8` | `"1uA"` | Liberty current unit string |
| `capacitive_load_unit` | `[]const u8` | `"1pf"` | Liberty capacitance unit string |
| `leaking_power_unit` | `[]const u8` | `"1nW"` | Liberty leakage power unit string |
| `model_lib_path` | `[]const u8` | `""` | Path to SPICE model library |
| `model_corner` | `[]const u8` | `"tt"` | Corner section in model library |
| `input_slew_ns` | `f64` | `0.1` | Default input slew for stimulus |
| `output_load_pf` | `f64` | `0.005` | Default output load |
| `sim_time_ns` | `f64` | `50.0` | Transient simulation time window |
| `vdd_net` | `[]const u8` | `"VDD"` | Supply net name |
| `vss_net` | `[]const u8` | `"VSS"` | Ground net name |
| `gds_db_unit_um` | `f64` | `0.001` | GDS database unit in µm (sky130) |
| `library_name` | `[]const u8` | `"spout_analog"` | Liberty `library()` name |
| `slew_indices` | `[]const f64` | 7 sky130 breakpoints | NLDM row axis (ns) |
| `load_indices` | `[]const f64` | 7 sky130 breakpoints | NLDM col axis (pF) |

Default slew breakpoints (ns): `0.0100, 0.0230, 0.0531, 0.1233, 0.2830, 0.6497, 1.5000`

Default load breakpoints (pF): `0.0005, 0.0012, 0.0030, 0.0074, 0.0181, 0.0445, 0.1093`

### `NldmTable`

A flat 2D array in row-major order (rows = input slew, columns = output load):

| Field | Type | Meaning |
|---|---|---|
| `values` | `[]f64` | Flat array of `rows × cols` values |
| `rows` | `usize` | Number of slew breakpoints |
| `cols` | `usize` | Number of load breakpoints |

Methods:
- `init(allocator, rows, cols) !NldmTable` — allocate zeroed table
- `scalar(allocator, rows, cols, val) !NldmTable` — allocate table filled with constant
- `deinit(allocator)` — free underlying slice
- `get(row, col) f64` — read one value (row-major indexing: `values[row * cols + col]`)
- `set(row, col, val)` — write one value

### `TimingArc`

One directional path from a `related_pin` to the owning pin:

| Field | Type | Meaning |
|---|---|---|
| `related_pin` | `[]const u8` | Driving input pin name |
| `timing_sense` | `TimingSense` | `positive_unate`, `negative_unate`, `non_unate` |
| `timing_type` | `TimingType` | `combinational`, `rising_edge`, `falling_edge`, etc. |
| `cell_rise` | `NldmTable` | Propagation delay to output rising (ns) |
| `cell_fall` | `NldmTable` | Propagation delay to output falling (ns) |
| `rise_transition` | `NldmTable` | Output 10%–90% rise transition time (ns) |
| `fall_transition` | `NldmTable` | Output 90%–10% fall transition time (ns) |
| `related_power_pin` | `?[]const u8` | Optional pg_pin for power supply |
| `related_ground_pin` | `?[]const u8` | Optional pg_pin for ground |

### `InternalPower`

Energy consumed per switching event:

| Field | Type | Meaning |
|---|---|---|
| `related_pin` | `[]const u8` | Input pin driving the transition |
| `rise_power` | `NldmTable` | Energy for rising output transition (pJ) |
| `fall_power` | `NldmTable` | Energy for falling output transition (pJ) |
| `related_pg_pin` | `?[]const u8` | Optional pg_pin providing power |

### `LibertyPin`

| Field | Type | Meaning |
|---|---|---|
| `name` | `[]const u8` | Pin name |
| `direction` | `PinDirection` | `input`, `output`, `inout`, `internal` |
| `capacitance` | `f64` | Input capacitance (pF) — measured via AC analysis |
| `max_capacitance` | `f64` | Max output load (pF) — set to largest load index |
| `timing_arcs` | `[]const TimingArc` | All timing arcs ending at this pin |
| `internal_power` | `[]const InternalPower` | Internal power entries for this pin |

### `LibertyCell`

| Field | Type | Meaning |
|---|---|---|
| `name` | `[]const u8` | Cell name (used in `cell()` group) |
| `area` | `f64` | Bounding-box area in µm² from GDS |
| `leakage_power` | `f64` | Quiescent DC leakage power in nW |
| `pins` | `[]const LibertyPin` | Signal pins only |
| `pg_pins` | `[]const PgPin` | Power and ground pins |

### `PgPin`

| Field | Type | Meaning |
|---|---|---|
| `name` | `[]const u8` | Pin name (e.g. `VPWR`, `VDD`) |
| `pg_type` | `PgPinType` | `primary_power`, `primary_ground`, `nwell`, `pwell` |
| `voltage_name` | `[]const u8` | Name from `voltage_map` declaration |

### `PinDirection` (enum)

Values: `input` (0), `output` (1), `inout` (2), `internal` (3)

### `TimingSense` (enum)

Values: `positive_unate` (0), `negative_unate` (1), `non_unate` (2)

### `TimingType` (enum)

Values: `combinational` (0), `rising_edge` (1), `falling_edge` (2), `setup_rising` (3), `setup_falling` (4), `hold_rising` (5), `hold_falling` (6)

### `PgPinType` (enum)

Values: `primary_power` (0), `primary_ground` (1), `nwell` (2), `pwell` (3)

---

## Main Entry Point (`lib.zig`)

### `generateLiberty`

```zig
pub fn generateLiberty(
    out: anytype,
    gds_path: []const u8,
    spice_path: []const u8,
    cell_name: []const u8,
    config: LibertyConfig,
    allocator: std.mem.Allocator,
) !void
```

Generates a complete `.lib` file for one cell. The five-step pipeline:

1. **GDS area extraction**: calls `gds_area.readBoundingBox(gds_path, config.gds_db_unit_um)` → `BoundingBox`. Area is computed as `bbox.areaUm2() * db_unit_um²`.
2. **SPICE netlist parsing**: creates `SimContext` from `spice_path` + `cell_name` + `config`. Parses the `.subckt` line to find all ports and classify them as VDD/VSS/nwell/pwell/signal_in/signal_out.
3. **Leakage power**: calls `sim_ctx.measureLeakagePower()` → DC operating point. Returns leakage in nW.
4. **Transient characterization**: calls `sim_ctx.characterizePins(allocator)` → runs ngspice for every `(slew, load)` combination in the NLDM grid. Returns `CharacterizationResult` with fully populated `LibertyPin` slice and `PgPin` slice.
5. **Liberty serialization**: builds a `LibertyCell` from the above, then calls `writer.writeLiberty(out, &cell, config)`.

### `CornerSpec`

A named PVT corner:

| Field | Type | Meaning |
|---|---|---|
| `name` | `[]const u8` | Liberty-style name, e.g. `"tt_025C_1v80"` |
| `model_corner` | `[]const u8` | Corner section in model library, e.g. `"tt"` |
| `nom_voltage` | `f64` | Supply voltage for this corner (V) |
| `nom_temperature` | `f64` | Temperature for this corner (°C) |

### Pre-defined `sky130_corners`

Three representative corners:

| Name | Corner | Voltage | Temperature |
|---|---|---|---|
| `tt_025C_1v80` | `tt` | 1.80 V | 25 °C |
| `ss_100C_1v60` | `ss` | 1.60 V | 100 °C |
| `ff_n40C_1v95` | `ff` | 1.95 V | −40 °C |

### `applyCorner`

```zig
pub fn applyCorner(base: LibertyConfig, corner: CornerSpec) LibertyConfig
```

Takes a `LibertyConfig` and a `CornerSpec` and returns a new config with `nom_voltage`, `nom_temperature`, `nom_process`, `model_corner`, and `library_name` all set from the corner. The caller loops over corners to generate one `.lib` file per corner.

### `generateLibertyAllCorners`

```zig
pub fn generateLibertyAllCorners(
    gds_path: []const u8,
    spice_path: []const u8,
    cell_name: []const u8,
    pdk_corner_set: *const pdk.PdkCornerSet,
    output_dir: []const u8,
    base_config: LibertyConfig,
    allocator: std.mem.Allocator,
) !u32
```

Generates one `.lib` file per PVT corner in `pdk_corner_set`. For each corner:
1. Calls `pdk_corner_set.generateCorners(allocator)` for the full cross-product list.
2. Applies each corner with `applyCorner`.
3. Writes to `{output_dir}/{cell_name}_{corner.name}.lib`.
4. Returns the count of files written.

---

## Liberty Writer (`writer.zig`)

### `writeLiberty`

```zig
pub fn writeLiberty(out: anytype, cell: *const LibertyCell, config: LibertyConfig) !void
```

The complete serializer. Calls sub-functions in order:
1. Library header fields (`technology`, `delay_model`, units, `nom_*`)
2. `voltage_map` declarations for VDD and VSS
3. `writeTableTemplate` twice — once for `delay_template_NxM`, once for `power_template_NxM`
4. `operating_conditions` group + `default_operating_conditions`
5. `cell()` group: `area`, `cell_leakage_power`
6. `writePgPin` for each pg_pin
7. `writePin` for each signal pin

### `writeTableTemplate`

```zig
fn writeTableTemplate(out, prefix, slew_len, load_len, index_1, index_2) !void
```

Emits an `lu_table_template` group. Template name is `{prefix}{slew_len}x{load_len}`. Variables are always `input_net_transition` and `total_output_net_capacitance`. Calls `writeIndexLine` for each axis.

### `writeIndexLine`

```zig
fn writeIndexLine(out, prefix, values) !void
```

Emits a quoted comma-separated list: `index_1 ("0.0100, 0.0230, ...");`. Values formatted to 4 decimal places.

### `writePgPin`

```zig
fn writePgPin(out, pg: *const PgPin) !void
```

Emits `pg_pin(NAME) { pg_type : ...; voltage_name : ...; }`.

### `writePin`

```zig
fn writePin(out, pin: *const LibertyPin, config: LibertyConfig) !void
```

Emits a `pin(NAME)` group. Omits `capacitance` if 0.0; omits `max_capacitance` if 0.0. Derives the template names from `config.slew_indices.len` and `config.load_indices.len`. Calls `writeTimingArc` and `writeInternalPower` for each arc/power entry.

### `writeTimingArc`

```zig
fn writeTimingArc(out, arc: *const TimingArc, delay_tpl: []const u8) !void
```

Emits a `timing()` group. Optional `related_power_pin` and `related_ground_pin` are included only when present. Calls `writeNldmBlock` four times.

### `writeInternalPower`

```zig
fn writeInternalPower(out, pwr: *const InternalPower, power_tpl: []const u8) !void
```

Emits an `internal_power()` group with `rise_power` and `fall_power` tables.

### `writeNldmBlock`

```zig
fn writeNldmBlock(out, name, template, table: *const NldmTable) !void
```

Emits one named table block: the `name(template_name) { values (...); }` block. Values are written row by row, each row as a quoted comma-separated string, rows separated by commas, last row without trailing comma. Values formatted to 6 decimal places.

### `inferTimingSense`

```zig
pub fn inferTimingSense(netlist_text, input_pin, output_pin) TimingSense
```

Heuristic: scans the SPICE netlist text for `"inv"`, `"INV"`, or `"Inv"` (case variants). If found, returns `negative_unate`. Otherwise returns the conservative `non_unate`. The `input_pin` and `output_pin` arguments are accepted but currently unused — they are reserved for future full topology tracing.

---

## PDK Corner Definitions (`pdk.zig`)

### `PdkId` (enum)

Values: `sky130`, `gf180mcu`

### `VoltageDomain`

| Field | Type | Meaning |
|---|---|---|
| `name` | `[]const u8` | Short label, e.g. `"1v8"`, `"3v3"` |
| `nom_voltages` | `[]const f64` | Nominal voltages for ss/tt/ff (V) |

### `PdkCornerSet`

The central descriptor for one PDK. All fields are comptime-constant slices:

| Field | Type | Meaning |
|---|---|---|
| `pdk` | `PdkId` | Which PDK |
| `model_lib_dir` | `[]const u8` | Relative path from PDK root to model directory |
| `model_file` | `[]const u8` | SPICE model library filename |
| `corner_names` | `[]const []const u8` | Process corner sections (e.g. `tt`, `ss`, `ff`, `sf`, `fs`) |
| `voltage_domains` | `[]const VoltageDomain` | Available voltage domains |
| `temperatures` | `[]const f64` | Temperature sweep points (°C) |
| `power_pin_names` | `[]const []const u8` | Power pin names for classification |
| `ground_pin_names` | `[]const []const u8` | Ground pin names for classification |
| `nwell_pin_names` | `[]const []const u8` | N-well bias pin names |
| `pwell_pin_names` | `[]const []const u8` | P-well bias pin names |
| `vdd_net` | `[]const u8` | Supply net name for Liberty `voltage_map` |
| `vss_net` | `[]const u8` | Ground net name for Liberty `voltage_map` |

#### `PdkCornerSet.modelLibPath`

```zig
pub fn modelLibPath(self, pdk_root, pdk_variant, buf) []const u8
```

Constructs the full path: `{pdk_root}/{pdk_variant}/{model_lib_dir}/{model_file}`. Example: `/home/user/.volare/sky130A/libs.tech/ngspice/sky130.lib.spice`.

#### `PdkCornerSet.generateCorners`

```zig
pub fn generateCorners(self, allocator) ![]CornerSpec
```

Generates the full Cartesian cross-product of `corner_names × nom_voltages × temperatures` using the first voltage domain. For sky130: 5 × 3 × 3 = 45 corners. Names are formatted via `formatCornerName`. Caller owns the returned slice and must free both the slice and each `.name` string.

#### `PdkCornerSet.classifyPortForPdk`

```zig
pub fn classifyPortForPdk(self, name) PortRole
```

Classifies a pin name using the PDK's own power/ground/well pin lists (case-insensitive). Falls through to heuristic `classifySignalPort` if no match.

### Corner Name Formatting

`formatCornerName` encodes: `{corner}_{temp}_{voltage}`. Examples:

| Input | Output |
|---|---|
| `tt`, 25 °C, 1.80 V | `tt_025C_1v80` |
| `ss`, 100 °C, 1.60 V | `ss_100C_1v60` |
| `ff`, −40 °C, 1.95 V | `ff_n40C_1v95` |

Temperature: negative uses `n` prefix + 2-digit zero-padded (`n40C`); non-negative uses 3-digit zero-padded (`025C`, `100C`, `125C`).

Voltage: whole part + `v` + 2-digit fractional part (`1v80`, `3v30`, `1v62`).

### Pre-defined PDK Constants

#### sky130

| Property | Value |
|---|---|
| `model_lib_dir` | `libs.tech/ngspice` |
| `model_file` | `sky130.lib.spice` |
| `corner_names` | `tt`, `ss`, `ff`, `sf`, `fs` |
| `nom_voltages` (1v8 domain) | 1.60, 1.80, 1.95 V |
| `temperatures` | −40, 25, 100 °C |
| `power_pin_names` | `VPWR`, `VDD`, `VDDA`, `AVDD` |
| `ground_pin_names` | `VGND`, `VSS`, `VSSA`, `AVSS`, `GND` |
| `nwell_pin_names` | `VPB` |
| `pwell_pin_names` | `VNB` |
| `vdd_net` | `VPWR` |
| `vss_net` | `VGND` |

Total sky130 corners: 5 × 3 × 3 = **45**

#### gf180mcu 3.3 V domain

| Property | Value |
|---|---|
| `model_lib_dir` | `libs.tech/ngspice` |
| `model_file` | `sm141064.ngspice` |
| `corner_names` | `tt`, `ss`, `ff`, `sf`, `fs` |
| `nom_voltages` (3v3 domain) | 3.0, 3.3, 3.6 V |
| `temperatures` | −40, 25, 125 °C |
| `power_pin_names` | `VDD`, `VDDA`, `AVDD` |
| `ground_pin_names` | `VSS`, `VSSA`, `AVSS`, `GND` |
| `nwell_pin_names` | (none) |
| `pwell_pin_names` | (none) |
| `vdd_net` | `VDD` |
| `vss_net` | `VSS` |

#### gf180mcu 1.8 V domain

Same as 3.3 V domain except `nom_voltages` = 1.62, 1.80, 1.98 V (domain name `1v8`).

### Lookup Functions

#### `fromName`

```zig
pub fn fromName(name: []const u8) ?*const PdkCornerSet
```

Recognised names (case-insensitive): `"sky130"`, `"gf180mcu_3v3"`, `"gf180mcu_1v8"`, `"gf180mcu"` (alias for `gf180mcu_3v3`). Returns `null` for unrecognised names.

#### `detectFromEnv`

```zig
pub fn detectFromEnv() ?*const PdkCornerSet
```

Reads the `$PDK` environment variable and passes its value to `fromName`. Returns `null` if the variable is unset or its value is not a recognised PDK.

---

## GDS Area Extraction (`gds_area.zig`)

### `BoundingBox`

Accumulates the spatial extents of all GDS geometry elements.

| Field | Type | Meaning |
|---|---|---|
| `x_min`, `y_min` | `i64` | Minimum coordinates in database units |
| `x_max`, `y_max` | `i64` | Maximum coordinates in database units |
| `valid` | `bool` | False until at least one coordinate is added |

Methods:
- `empty() BoundingBox` — initializes with sentinel extremes
- `extend(x, y)` — expands the box to include point (x, y)
- `areaUm2() f64` — returns `(x_max - x_min) * (y_max - y_min)` in db-units² (caller multiplies by `db_unit_um²`)
- `width() f64` — `x_max - x_min` in db units
- `height() f64` — `y_max - y_min` in db units

### `readBoundingBox`

```zig
pub fn readBoundingBox(gds_path: []const u8, db_unit_um: f64) !BoundingBox
```

Opens the GDSII binary file and scans all records. State machine:
- Tracks `in_element` flag: set on `BOUNDARY` or `PATH` records, cleared on `ENDEL`
- On `XY` record inside an element: reads all (x, y) coordinate pairs and calls `bbox.extend`
- Stops on `ENDLIB`

GDSII record format: `[u16 BE length] [u8 record_type] [u8 data_type] [payload]`

### `readBoundingBoxFromMemory`

Same logic as `readBoundingBox` but operates on an in-memory byte slice. Used in tests.

---

## Operating Conditions and PVT Corners

Spout supports three axes of variation:

- **Process (P)**: `tt` (typical-typical), `ss` (slow-slow), `ff` (fast-fast), `sf` (slow PMOS / fast NMOS), `fs` (fast PMOS / slow NMOS)
- **Voltage (V)**: varies by PDK and domain. Sky130: 1.60 V (worst-case low), 1.80 V (nominal), 1.95 V (best-case high)
- **Temperature (T)**: sky130: −40 °C (cold), 25 °C (nominal), 100 °C (hot)

Each PVT corner becomes one `.lib` file named `{cell}_{corner}.lib`, e.g. `current_mirror_ss_100C_1v60.lib`. The file's `operating_conditions` group and `nom_*` fields reflect the exact corner.

The `model_corner` field in `LibertyConfig` is used in the ngspice deck `.lib "{path}" {corner}` include statement to select the matching SPICE model section.

---

## Integration with Synthesis Tools

Liberty files produced by Spout are consumed by:

- **OpenSTA**: reads `.lib` for static timing analysis via `read_liberty`. Uses `nom_voltage`, `nom_temperature`, `nom_process`, `operating_conditions`, and all NLDM tables.
- **Yosys**: reads `.lib` for technology mapping via `read_liberty`. Uses `area`, `pin` directions, and `timing_sense` for functional equivalence.
- **OpenROAD**: reads `.lib` for placement, global routing estimations, and post-route timing. Uses `pg_pin`, `voltage_map`, and all timing/power tables.

The `delay_model : table_lookup` declaration tells all tools to use NLDM bilinear interpolation from the tables rather than any analytic model.

---

## Structure Diagram

```svg
<svg viewBox="0 0 900 700" xmlns="http://www.w3.org/2000/svg" font-family="'Inter', 'Segoe UI', sans-serif">
  <rect width="900" height="700" fill="#060C18"/>

  <!-- Title -->
  <text x="450" y="36" text-anchor="middle" fill="#00C4E8" font-size="18" font-weight="bold">Liberty File Structure &amp; Data Flow</text>

  <!-- Data flow: PDK JSON → Generator → .lib -->
  <!-- PDK JSON box -->
  <rect x="20" y="60" width="140" height="80" rx="6" fill="#09111F" stroke="#14263E" stroke-width="1.5"/>
  <text x="90" y="88" text-anchor="middle" fill="#00C4E8" font-size="12" font-weight="bold">PDK JSON</text>
  <text x="90" y="106" text-anchor="middle" fill="#B8D0E8" font-size="10">sky130.json</text>
  <text x="90" y="122" text-anchor="middle" fill="#3E5E80" font-size="9">layers, DRC rules,</text>
  <text x="90" y="134" text-anchor="middle" fill="#3E5E80" font-size="9">voltages, corners</text>

  <!-- Arrow PDK → pdk.zig -->
  <line x1="160" y1="100" x2="200" y2="100" stroke="#00C4E8" stroke-width="1.5" marker-end="url(#arr)"/>

  <!-- pdk.zig box -->
  <rect x="200" y="60" width="130" height="80" rx="6" fill="#09111F" stroke="#14263E" stroke-width="1.5"/>
  <text x="265" y="88" text-anchor="middle" fill="#00C4E8" font-size="12" font-weight="bold">pdk.zig</text>
  <text x="265" y="106" text-anchor="middle" fill="#B8D0E8" font-size="10">PdkCornerSet</text>
  <text x="265" y="122" text-anchor="middle" fill="#3E5E80" font-size="9">generateCorners()</text>
  <text x="265" y="134" text-anchor="middle" fill="#3E5E80" font-size="9">45 PVT corners</text>

  <!-- Arrow pdk → generateLiberty -->
  <line x1="330" y1="100" x2="370" y2="100" stroke="#00C4E8" stroke-width="1.5" marker-end="url(#arr)"/>

  <!-- generateLiberty box -->
  <rect x="370" y="60" width="150" height="80" rx="6" fill="#09111F" stroke="#1A3A5E" stroke-width="1.5"/>
  <text x="445" y="84" text-anchor="middle" fill="#00C4E8" font-size="12" font-weight="bold">generateLiberty</text>
  <text x="445" y="102" text-anchor="middle" fill="#B8D0E8" font-size="9">1. GDS → area</text>
  <text x="445" y="116" text-anchor="middle" fill="#B8D0E8" font-size="9">2. SPICE → ports</text>
  <text x="445" y="130" text-anchor="middle" fill="#B8D0E8" font-size="9">3. ngspice → tables</text>

  <!-- Arrow gen → .lib -->
  <line x1="520" y1="100" x2="560" y2="100" stroke="#00C4E8" stroke-width="1.5" marker-end="url(#arr)"/>

  <!-- .lib file box -->
  <rect x="560" y="60" width="120" height="80" rx="6" fill="#09111F" stroke="#14263E" stroke-width="1.5"/>
  <text x="620" y="88" text-anchor="middle" fill="#43A047" font-size="12" font-weight="bold">.lib file</text>
  <text x="620" y="106" text-anchor="middle" fill="#B8D0E8" font-size="10">Liberty output</text>
  <text x="620" y="122" text-anchor="middle" fill="#3E5E80" font-size="9">OpenSTA / Yosys /</text>
  <text x="620" y="134" text-anchor="middle" fill="#3E5E80" font-size="9">OpenROAD</text>

  <!-- Arrow to tools -->
  <line x1="680" y1="100" x2="720" y2="100" stroke="#43A047" stroke-width="1.5" marker-end="url(#arr2)"/>
  <rect x="720" y="60" width="150" height="80" rx="6" fill="#09111F" stroke="#14263E" stroke-width="1.5"/>
  <text x="795" y="88" text-anchor="middle" fill="#43A047" font-size="11" font-weight="bold">STA / Synthesis</text>
  <text x="795" y="106" text-anchor="middle" fill="#3E5E80" font-size="9">OpenSTA</text>
  <text x="795" y="120" text-anchor="middle" fill="#3E5E80" font-size="9">Yosys</text>
  <text x="795" y="134" text-anchor="middle" fill="#3E5E80" font-size="9">OpenROAD</text>

  <!-- ───── Liberty file hierarchy ───── -->
  <!-- library outer box -->
  <rect x="20" y="175" width="860" height="490" rx="8" fill="#09111F" stroke="#14263E" stroke-width="2"/>
  <text x="40" y="200" fill="#00C4E8" font-size="13" font-weight="bold">library(spout_analog) {</text>

  <!-- Header fields -->
  <rect x="40" y="212" width="200" height="100" rx="4" fill="#060C18" stroke="#14263E" stroke-width="1"/>
  <text x="50" y="232" fill="#1E88E5" font-size="11" font-weight="bold">Header</text>
  <text x="50" y="249" fill="#3E5E80" font-size="9">technology (cmos)</text>
  <text x="50" y="263" fill="#3E5E80" font-size="9">delay_model : table_lookup</text>
  <text x="50" y="277" fill="#3E5E80" font-size="9">time_unit, voltage_unit ...</text>
  <text x="50" y="291" fill="#3E5E80" font-size="9">nom_voltage : 1.800</text>
  <text x="50" y="305" fill="#3E5E80" font-size="9">nom_temperature : 25.0</text>

  <!-- lu_table_template box -->
  <rect x="258" y="212" width="200" height="100" rx="4" fill="#060C18" stroke="#14263E" stroke-width="1"/>
  <text x="268" y="232" fill="#1E88E5" font-size="11" font-weight="bold">lu_table_template</text>
  <text x="268" y="249" fill="#B8D0E8" font-size="9">delay_template_7x7</text>
  <text x="268" y="263" fill="#B8D0E8" font-size="9">power_template_7x7</text>
  <text x="268" y="278" fill="#3E5E80" font-size="9">variable_1: slew</text>
  <text x="268" y="292" fill="#3E5E80" font-size="9">variable_2: load</text>
  <text x="268" y="306" fill="#3E5E80" font-size="9">index_1, index_2 breakpoints</text>

  <!-- operating_conditions box -->
  <rect x="476" y="212" width="200" height="100" rx="4" fill="#060C18" stroke="#14263E" stroke-width="1"/>
  <text x="486" y="232" fill="#1E88E5" font-size="11" font-weight="bold">operating_conditions</text>
  <text x="486" y="249" fill="#B8D0E8" font-size="9">"typical" / "tt_025C_1v80"</text>
  <text x="486" y="264" fill="#3E5E80" font-size="9">process : 1</text>
  <text x="486" y="278" fill="#3E5E80" font-size="9">voltage : 1.800</text>
  <text x="486" y="292" fill="#3E5E80" font-size="9">temperature : 25.0</text>
  <text x="486" y="307" fill="#3E5E80" font-size="9">default_operating_conditions</text>

  <!-- voltage_map box -->
  <rect x="694" y="212" width="166" height="100" rx="4" fill="#060C18" stroke="#14263E" stroke-width="1"/>
  <text x="704" y="232" fill="#1E88E5" font-size="11" font-weight="bold">voltage_map</text>
  <text x="704" y="249" fill="#B8D0E8" font-size="9">VDD → 1.80 V</text>
  <text x="704" y="263" fill="#B8D0E8" font-size="9">VSS → 0.00 V</text>

  <!-- cell box -->
  <rect x="40" y="332" width="840" height="312" rx="6" fill="#0C1828" stroke="#1A3A5E" stroke-width="1.5"/>
  <text x="58" y="356" fill="#00C4E8" font-size="12" font-weight="bold">cell(current_mirror) {  area : 125.6;  cell_leakage_power : 0.85;</text>

  <!-- pg_pin boxes -->
  <rect x="58" y="366" width="120" height="60" rx="4" fill="#0F2040" stroke="#1A5080" stroke-width="1"/>
  <text x="118" y="385" text-anchor="middle" fill="#1E88E5" font-size="10" font-weight="bold">pg_pin(VDD)</text>
  <text x="118" y="401" text-anchor="middle" fill="#3E5E80" font-size="9">primary_power</text>
  <text x="118" y="415" text-anchor="middle" fill="#3E5E80" font-size="9">voltage_name: VDD</text>

  <rect x="188" y="366" width="120" height="60" rx="4" fill="#0F2040" stroke="#1A5080" stroke-width="1"/>
  <text x="248" y="385" text-anchor="middle" fill="#1E88E5" font-size="10" font-weight="bold">pg_pin(VSS)</text>
  <text x="248" y="401" text-anchor="middle" fill="#3E5E80" font-size="9">primary_ground</text>
  <text x="248" y="415" text-anchor="middle" fill="#3E5E80" font-size="9">voltage_name: VSS</text>

  <!-- input pin box -->
  <rect x="58" y="440" width="160" height="65" rx="4" fill="#0F2040" stroke="#1A5080" stroke-width="1"/>
  <text x="138" y="459" text-anchor="middle" fill="#00C4E8" font-size="10" font-weight="bold">pin(INP)</text>
  <text x="138" y="475" text-anchor="middle" fill="#B8D0E8" font-size="9">direction : input</text>
  <text x="138" y="489" text-anchor="middle" fill="#3E5E80" font-size="9">capacitance : 0.002 pF</text>
  <text x="138" y="502" text-anchor="middle" fill="#3E5E80" font-size="8">(measured via AC sim)</text>

  <!-- output pin box (larger) -->
  <rect x="240" y="440" width="620" height="190" rx="4" fill="#0F2040" stroke="#1A5080" stroke-width="1"/>
  <text x="280" y="459" fill="#00C4E8" font-size="10" font-weight="bold">pin(OUT)  direction : output  max_capacitance : 0.1 pF</text>

  <!-- timing arc box -->
  <rect x="256" y="468" width="290" height="150" rx="3" fill="#060C18" stroke="#1A3A5E" stroke-width="1"/>
  <text x="401" y="486" text-anchor="middle" fill="#AB47BC" font-size="10" font-weight="bold">timing() { related_pin : "INP" }</text>
  <text x="401" y="502" text-anchor="middle" fill="#3E5E80" font-size="9">timing_sense : negative_unate</text>
  <text x="401" y="517" text-anchor="middle" fill="#3E5E80" font-size="9">timing_type : combinational</text>

  <!-- NLDM mini grid -->
  <text x="270" y="534" fill="#B8D0E8" font-size="8">cell_rise(delay_template_7x7)</text>
  <!-- tiny grid cells -->
  <rect x="270" y="538" width="14" height="10" fill="#062030" stroke="#0A3050" stroke-width="0.5"/>
  <rect x="284" y="538" width="14" height="10" fill="#083040" stroke="#0A3050" stroke-width="0.5"/>
  <rect x="298" y="538" width="14" height="10" fill="#0A4060" stroke="#0A3050" stroke-width="0.5"/>
  <rect x="312" y="538" width="14" height="10" fill="#0C5080" stroke="#0A3050" stroke-width="0.5"/>
  <rect x="326" y="538" width="14" height="10" fill="#0E60A0" stroke="#0A3050" stroke-width="0.5"/>
  <rect x="340" y="538" width="14" height="10" fill="#1070C0" stroke="#0A3050" stroke-width="0.5"/>
  <rect x="354" y="538" width="14" height="10" fill="#00C4E8" stroke="#0A3050" stroke-width="0.5"/>
  <rect x="270" y="548" width="14" height="10" fill="#083040" stroke="#0A3050" stroke-width="0.5"/>
  <rect x="284" y="548" width="14" height="10" fill="#0A4060" stroke="#0A3050" stroke-width="0.5"/>
  <rect x="298" y="548" width="14" height="10" fill="#0C5080" stroke="#0A3050" stroke-width="0.5"/>
  <rect x="312" y="548" width="14" height="10" fill="#0E60A0" stroke="#0A3050" stroke-width="0.5"/>
  <rect x="326" y="548" width="14" height="10" fill="#1070C0" stroke="#0A3050" stroke-width="0.5"/>
  <rect x="340" y="548" width="14" height="10" fill="#00C4E8" stroke="#0A3050" stroke-width="0.5"/>
  <rect x="354" y="548" width="14" height="10" fill="#20D0F0" stroke="#0A3050" stroke-width="0.5"/>

  <text x="270" y="575" fill="#3E5E80" font-size="8">index_1 (slew) →</text>
  <text x="270" y="587" fill="#3E5E80" font-size="8">index_2 (load) ↓  (7×7 grid shown)</text>
  <text x="270" y="600" fill="#3E5E80" font-size="8">cell_fall, rise_transition, fall_transition</text>

  <!-- internal_power box -->
  <rect x="558" y="468" width="290" height="150" rx="3" fill="#060C18" stroke="#1A3A5E" stroke-width="1"/>
  <text x="703" y="486" text-anchor="middle" fill="#FB8C00" font-size="10" font-weight="bold">internal_power() { related_pin : "INP" }</text>
  <text x="703" y="502" text-anchor="middle" fill="#3E5E80" font-size="9">rise_power(power_template_7x7)</text>
  <text x="703" y="517" text-anchor="middle" fill="#3E5E80" font-size="9">fall_power(power_template_7x7)</text>
  <text x="703" y="534" text-anchor="middle" fill="#3E5E80" font-size="9">values in picojoules</text>
  <text x="703" y="550" text-anchor="middle" fill="#3E5E80" font-size="9">2D: slew × load</text>

  <!-- closing braces -->
  <text x="40" y="648" fill="#3E5E80" font-size="11">  }  ← end cell</text>
  <text x="20" y="668" fill="#3E5E80" font-size="11">}  ← end library</text>

  <!-- arrowhead marker -->
  <defs>
    <marker id="arr" markerWidth="8" markerHeight="8" refX="6" refY="3" orient="auto">
      <path d="M0,0 L0,6 L8,3 z" fill="#00C4E8"/>
    </marker>
    <marker id="arr2" markerWidth="8" markerHeight="8" refX="6" refY="3" orient="auto">
      <path d="M0,0 L0,6 L8,3 z" fill="#43A047"/>
    </marker>
  </defs>
</svg>
```
