# Characterization Flow

Cell characterization is the process of running SPICE simulations across a grid of operating conditions to populate the NLDM lookup tables in Liberty `.lib` files. This gives synthesis and static timing analysis tools accurate, simulation-grounded data about how a cell behaves — its propagation delay, output slew, and switching energy — as a function of input signal quality (slew rate) and output loading (capacitance).

---

## What Characterization Means

A standard cell's timing characteristics are not constant. A slow input transition causes a slow output transition; a large capacitive load increases propagation delay and output transition time. Characterization maps this two-dimensional parameter space by running SPICE simulations at each grid point:

```
For each process corner (tt / ss / ff / sf / fs):
  For each supply voltage (e.g. 1.60 / 1.80 / 1.95 V):
    For each temperature (e.g. -40 / 25 / 100 °C):
      For each cell port pair (input → output):
        For each slew breakpoint s in slew_indices:
          For each load breakpoint l in load_indices:
            simulate → measure tpd_rise, tpd_fall, t_rise, t_fall, power
```

For sky130 with the default 7 × 7 grid, a cell with 2 inputs and 1 output: 2 arcs × 49 points × 45 PVT corners = **4,410 SPICE simulations** to fully characterize all corners.

---

## Required Inputs

| Input | Source | Description |
|---|---|---|
| GDSII file | `gds_path` | Physical layout for bounding-box area extraction |
| SPICE netlist | `spice_path` | `.subckt` definition of the cell |
| PDK model library | `config.model_lib_path` | SPICE transistor model files (sky130: `sky130.lib.spice`) |
| Model corner section | `config.model_corner` | Which section of the model library to `.lib` include (e.g. `tt`) |
| Operating conditions | `LibertyConfig` | Nominal voltage, temperature, net names |
| NLDM breakpoints | `LibertyConfig.slew_indices`, `load_indices` | Grid axis values |

---

## Implementation: `spice_sim.zig`

The entire characterization engine lives in `src/liberty/spice_sim.zig`. The orchestrating struct is `SimContext`.

### `SimContext.init`

```zig
pub fn init(allocator, spice_path, cell_name, config) !SimContext
```

1. Opens and reads the SPICE file into `spice_content: []u8`
2. Calls `parseSubcktPorts` to extract port names and roles
3. Stores allocator, config, cell_name, ports

### `parseSubcktPorts`

```zig
fn parseSubcktPorts(allocator, spice_content, cell_name) ![]PortInfo
```

Scans lines of the SPICE netlist for a `.subckt <cell_name>` declaration. Tokenizes the rest of the line (stopping at `=` or `*`/`$` comment markers) to extract port names. Classifies each port by name using `classifyPort`.

Port classification rules in `classifyPort`:
- `VPB` → `nwell`
- `VNB` → `pwell`
- `VDD`, `VPWR`, `VDDA`, `AVDD` → `vdd`
- `VSS`, `VGND`, `GND`, `VSSA`, `AVSS` → `vss`
- Contains `OUT` or `VOUT` (case-insensitive) → `signal_out`
- Single char `Y`, `Q`, `y`, `q` → `signal_out`
- Everything else → `signal_in`

### `characterizePins`

```zig
pub fn characterizePins(self: *SimContext, allocator) !CharacterizationResult
```

Separates the port list into inputs, outputs, and pg_pins. For each input pin calls `measureInputCap`. For each output pin calls `measureTimingArc` for every input→output combination. Returns a `CharacterizationResult` with `pins: []LibertyPin` and `pg_pins: []PgPin`.

### `measureTimingArc`

```zig
fn measureTimingArc(self, allocator, input_pin, output_pin) !TimingResult
```

Infers timing sense via `inferTimingSense` heuristic, then allocates four `NldmTable`s (cell_rise, cell_fall, rise_transition, fall_transition) and two power tables (rise_power, fall_power). Runs the full `slew_count × load_count` sweep, calling `measureSinglePoint` for each grid cell.

### `measureSinglePoint`

```zig
fn measureSinglePoint(self, input_pin, output_pin, slew_ns, load_pf) !PointResult
```

Generates an ngspice testbench deck and runs it. Returns:
- `tpd_rise_ns` — rising propagation delay (ns)
- `tpd_fall_ns` — falling propagation delay (ns)
- `t_rise_ns` — output rise transition 10%–90% (ns)
- `t_fall_ns` — output fall transition 90%–10% (ns)
- `rise_pj` — energy per rising switch (pJ)
- `fall_pj` — energy per falling switch (pJ)

### Testbench Deck Generation (`writeDeckHeader`)

The deck includes:
1. Comment header
2. `.lib "{model_lib_path}" {model_corner}` (if model_lib_path is non-empty)
3. The full SPICE netlist verbatim
4. `xdut {port_list} {cell_name}` — DUT instantiation
5. `vvdd {vdd_net} 0 dc {nom_voltage}` — supply
6. `vvss {vss_net} 0 dc 0` — ground
7. Well-bias sources for nwell/pwell pins

Then for a transient run, `measureSinglePoint` appends:
8. `vpulse` on the active input with the specified slew
9. Mid-rail biases for inactive signal inputs
10. `cload {output} 0 {load_pf}p`
11. `.control` block with `tran`, `meas` statements, and `echo` for result extraction

### Testbench Pulse Parameters

The pulse stimulus uses:
- Start time: `half / 2.0` where `half = sim_time_ns / 4`
- Rise time: `slew_ns`
- Fall time: `slew_ns`
- Pulse width: `half` (25% of total window)
- Period: `sim_time_ns` (one complete cycle)

This ensures the rising edge triggers at ~12.5% into the simulation window and the falling edge at ~37.5%, leaving the second half for the fall arc measurement.

### ngspice Execution (`runNgspice`)

Writes the deck to `/tmp/spout_liberty_deck.sp`, then invokes:
```
ngspice -b /tmp/spout_liberty_deck.sp
```

Captures stdout (up to 1 MB). If ngspice is not found or returns a non-zero exit code, returns an empty string (triggering fallback values for all measurements).

### `measureLeakagePower`

Generates a DC operating point deck with all signal inputs biased at `VDD/2`. Uses ngspice `.control` with `op` command and `let i_leak = abs(i(vvdd))`. Converts from amps to nanowatts: `nW = A × V × 1e9`.

### `measureInputCap`

AC analysis at 1 MHz:
- AC voltage source on the pin (DC bias at VDD/2)
- `ac dec 1 1e6 1e6`
- Computes `cin = 1 / (2π × 1 MHz × imag(1/i(vac)))` in the `.control` block
- Result in pF (converted from farads)

---

## Current Implementation State

From `src/characterize/TODO.md`:

> "This is fully vibe-coded here... - Not functional, so we use magic/klayout as dependencies."

This note refers specifically to the `src/characterize/` subsystem (DRC/LVS/PEX), which is the layout verification and extraction layer. The Liberty characterization subsystem in `src/liberty/` is a separate codebase and is functionally implemented with working ngspice integration.

### What Is Working (Liberty subsystem)

- Complete Liberty file format output (`writer.zig`) — verified by integration tests
- GDS bounding-box area extraction (`gds_area.zig`) — tested with synthetic GDSII
- SPICE netlist port parsing (`spice_sim.zig`) — tested with `.subckt` examples
- Full NLDM sweep infrastructure (`measureTimingArc`, `measureSinglePoint`) — implemented
- Leakage power measurement (`measureLeakagePower`) — implemented
- Input capacitance AC measurement (`measureInputCap`) — implemented
- PDK corner enumeration and naming (`pdk.zig`) — fully tested (45 corners for sky130)
- Multi-corner Liberty generation (`generateLibertyAllCorners`) — implemented
- Port classification (VDD/VSS/nwell/pwell/signal) — tested

### What Requires ngspice at Runtime

The simulation steps (`measureSinglePoint`, `measureLeakagePower`, `measureInputCap`) require `ngspice` to be on `$PATH`. They degrade gracefully if ngspice is absent: `runNgspice` returns an empty string, and all measurements fall back to conservative default values. This means Liberty files are always produced, but with placeholder table data until real simulations run.

### DRC/LVS/PEX Subsystem (`src/characterize/`)

This is the separate physical verification layer:
- `drc.zig` — Design Rule Check (DRC) using Magic/KLayout as backend
- `lvs.zig` — Layout vs. Schematic verification
- `pex.zig` — Parasitic Extraction (RC parasitics for post-layout simulation)
- `ext2spice.zig` — Converts extracted parasitic data to SPICE format

The TODO note indicates this subsystem relies on external tools (Magic, KLayout) as dependencies rather than being self-contained. These tools are used to provide the DRC deck logic, layout parasitic extraction, and LVS comparison that Spout does not yet implement natively.

---

## Integration with PDK SPICE Models

### sky130 Model Structure

For sky130, the model library lives at:
```
$PDK_ROOT/sky130A/libs.tech/ngspice/sky130.lib.spice
```

This file contains named sections selectable by the `.lib "..." section` syntax:
- `tt` — typical-typical corner
- `ss` — slow-slow corner
- `ff` — fast-fast corner
- `sf` — slow PMOS / fast NMOS corner
- `fs` — fast PMOS / slow NMOS corner

`PdkCornerSet.modelLibPath` constructs the full path given `$PDK_ROOT` and the variant (e.g. `sky130A`). The corner section name comes from `CornerSpec.model_corner`.

### Model Library Include in Deck

When `config.model_lib_path` is non-empty, the testbench deck begins with:
```spice
.lib "/path/to/sky130.lib.spice" tt
```

This selects the `tt` section, loading the appropriate MOSFET model parameters for that process corner. The supply voltage and temperature are set by the DC/transient sources and the `nom_voltage`/`nom_temperature` config fields respectively.

---

## Measurement Details

### Propagation Delay Thresholds

Both rising and falling delays are measured at **50% of VDD** crossings:
- `tpd_rise`: input falls through 50% VDD (trigger), output rises through 50% VDD (target)
- `tpd_fall`: input rises through 50% VDD (trigger), output falls through 50% VDD (target)

This is the standard IEEE 50%-to-50% propagation delay definition.

### Transition Time Thresholds

- Rise transition: output crosses **10% VDD** (trigger) to **90% VDD** (target)
- Fall transition: output crosses **90% VDD** (trigger) to **10% VDD** (target)

This matches the Liberty standard 10%/90% slew measurement convention.

### Energy Measurement

Average supply current is sampled over a narrow window centered on each switching event:
- Rise window: 40% to 60% of half-period (centered on rising edge)
- Fall window: 140% to 160% of half-period (centered on falling edge)

Energy: `E = VDD × I_avg × Δt` where `Δt = 2 × slew_ns` (the rise+fall time of the stimulus). Result in pJ.

---

## Characterization Flowchart

```svg
<svg viewBox="0 0 900 620" xmlns="http://www.w3.org/2000/svg" font-family="'Inter', 'Segoe UI', sans-serif">
  <rect width="900" height="620" fill="#060C18"/>
  <text x="450" y="34" text-anchor="middle" fill="#00C4E8" font-size="18" font-weight="bold">Characterization Pipeline</text>

  <!-- Arrowhead markers -->
  <defs>
    <marker id="arr" markerWidth="8" markerHeight="8" refX="6" refY="3" orient="auto">
      <path d="M0,0 L0,6 L8,3 z" fill="#00C4E8"/>
    </marker>
    <marker id="arrg" markerWidth="8" markerHeight="8" refX="6" refY="3" orient="auto">
      <path d="M0,0 L0,6 L8,3 z" fill="#43A047"/>
    </marker>
    <marker id="arram" markerWidth="8" markerHeight="8" refX="6" refY="3" orient="auto">
      <path d="M0,0 L0,6 L8,3 z" fill="#FB8C00"/>
    </marker>
  </defs>

  <!-- Stage 1: Inputs -->
  <rect x="20" y="60" width="200" height="480" rx="8" fill="#09111F" stroke="#14263E" stroke-width="1.5"/>
  <text x="120" y="85" text-anchor="middle" fill="#B8D0E8" font-size="12" font-weight="bold">INPUTS</text>

  <rect x="36" y="96" width="168" height="62" rx="4" fill="#060C18" stroke="#1A3A5E" stroke-width="1"/>
  <text x="120" y="117" text-anchor="middle" fill="#1E88E5" font-size="11" font-weight="bold">GDS Layout</text>
  <text x="120" y="135" text-anchor="middle" fill="#3E5E80" font-size="9">cell_name.gds</text>
  <text x="120" y="150" text-anchor="middle" fill="#3E5E80" font-size="9">BOUNDARY/PATH records</text>

  <rect x="36" y="170" width="168" height="62" rx="4" fill="#060C18" stroke="#1A3A5E" stroke-width="1"/>
  <text x="120" y="191" text-anchor="middle" fill="#1E88E5" font-size="11" font-weight="bold">SPICE Netlist</text>
  <text x="120" y="209" text-anchor="middle" fill="#3E5E80" font-size="9">cell_name.spice</text>
  <text x="120" y="224" text-anchor="middle" fill="#3E5E80" font-size="9">.subckt port list</text>

  <rect x="36" y="244" width="168" height="62" rx="4" fill="#060C18" stroke="#1A3A5E" stroke-width="1"/>
  <text x="120" y="265" text-anchor="middle" fill="#1E88E5" font-size="11" font-weight="bold">PDK Models</text>
  <text x="120" y="283" text-anchor="middle" fill="#3E5E80" font-size="9">sky130.lib.spice</text>
  <text x="120" y="298" text-anchor="middle" fill="#3E5E80" font-size="9">tt / ss / ff corners</text>

  <rect x="36" y="318" width="168" height="62" rx="4" fill="#060C18" stroke="#1A3A5E" stroke-width="1"/>
  <text x="120" y="339" text-anchor="middle" fill="#1E88E5" font-size="11" font-weight="bold">LibertyConfig</text>
  <text x="120" y="357" text-anchor="middle" fill="#3E5E80" font-size="9">VDD=1.8V, T=25°C</text>
  <text x="120" y="372" text-anchor="middle" fill="#3E5E80" font-size="9">slew_indices, load_indices</text>

  <rect x="36" y="392" width="168" height="62" rx="4" fill="#060C18" stroke="#1A3A5E" stroke-width="1"/>
  <text x="120" y="413" text-anchor="middle" fill="#1E88E5" font-size="11" font-weight="bold">Stimulus Grid</text>
  <text x="120" y="431" text-anchor="middle" fill="#3E5E80" font-size="9">7 slew × 7 load = 49 pts</text>
  <text x="120" y="446" text-anchor="middle" fill="#3E5E80" font-size="9">per arc per corner</text>

  <!-- Arrow: Inputs → Simulation -->
  <line x1="220" y1="300" x2="268" y2="300" stroke="#00C4E8" stroke-width="2" marker-end="url(#arr)"/>

  <!-- Stage 2: Simulation -->
  <rect x="268" y="60" width="210" height="480" rx="8" fill="#09111F" stroke="#14263E" stroke-width="1.5"/>
  <text x="373" y="85" text-anchor="middle" fill="#B8D0E8" font-size="12" font-weight="bold">SIMULATION</text>

  <rect x="284" y="96" width="178" height="56" rx="4" fill="#060C18" stroke="#1A3A5E" stroke-width="1"/>
  <text x="373" y="117" text-anchor="middle" fill="#00C4E8" font-size="11" font-weight="bold">Area Extraction</text>
  <text x="373" y="134" text-anchor="middle" fill="#3E5E80" font-size="9">gds_area.readBoundingBox()</text>
  <text x="373" y="148" text-anchor="middle" fill="#3E5E80" font-size="9">BOUNDARY/PATH → bbox</text>

  <rect x="284" y="164" width="178" height="56" rx="4" fill="#060C18" stroke="#1A3A5E" stroke-width="1"/>
  <text x="373" y="185" text-anchor="middle" fill="#00C4E8" font-size="11" font-weight="bold">Port Classification</text>
  <text x="373" y="202" text-anchor="middle" fill="#3E5E80" font-size="9">parseSubcktPorts()</text>
  <text x="373" y="218" text-anchor="middle" fill="#3E5E80" font-size="9">VDD/VSS/nwell/signal</text>

  <rect x="284" y="232" width="178" height="56" rx="4" fill="#060C18" stroke="#1A3A5E" stroke-width="1"/>
  <text x="373" y="253" text-anchor="middle" fill="#00C4E8" font-size="11" font-weight="bold">DC Leakage Sim</text>
  <text x="373" y="270" text-anchor="middle" fill="#3E5E80" font-size="9">measureLeakagePower()</text>
  <text x="373" y="286" text-anchor="middle" fill="#3E5E80" font-size="9">ngspice op → nW</text>

  <rect x="284" y="300" width="178" height="56" rx="4" fill="#060C18" stroke="#1A3A5E" stroke-width="1"/>
  <text x="373" y="321" text-anchor="middle" fill="#00C4E8" font-size="11" font-weight="bold">AC Cap Sim</text>
  <text x="373" y="338" text-anchor="middle" fill="#3E5E80" font-size="9">measureInputCap()</text>
  <text x="373" y="354" text-anchor="middle" fill="#3E5E80" font-size="9">ngspice ac 1MHz → pF</text>

  <rect x="284" y="368" width="178" height="96" rx="4" fill="#060C18" stroke="#1A3A5E" stroke-width="1"/>
  <text x="373" y="389" text-anchor="middle" fill="#00C4E8" font-size="11" font-weight="bold">Transient NLDM Sweep</text>
  <text x="373" y="407" text-anchor="middle" fill="#3E5E80" font-size="9">measureTimingArc()</text>
  <text x="373" y="422" text-anchor="middle" fill="#3E5E80" font-size="9">for each (slew, load):</text>
  <text x="373" y="437" text-anchor="middle" fill="#3E5E80" font-size="9">  measureSinglePoint()</text>
  <text x="373" y="452" text-anchor="middle" fill="#3E5E80" font-size="9">  ngspice -b deck.sp</text>
  <text x="373" y="467" text-anchor="middle" fill="#3E5E80" font-size="9">  parse stdout → meas</text>

  <!-- Arrow: Simulation → Measurement -->
  <line x1="478" y1="300" x2="526" y2="300" stroke="#00C4E8" stroke-width="2" marker-end="url(#arr)"/>

  <!-- Stage 3: Measurement -->
  <rect x="526" y="60" width="180" height="480" rx="8" fill="#09111F" stroke="#14263E" stroke-width="1.5"/>
  <text x="616" y="85" text-anchor="middle" fill="#B8D0E8" font-size="12" font-weight="bold">MEASUREMENT</text>

  <rect x="542" y="96" width="148" height="56" rx="4" fill="#060C18" stroke="#1A3A5E" stroke-width="1"/>
  <text x="616" y="116" text-anchor="middle" fill="#FB8C00" font-size="11" font-weight="bold">tpd_rise</text>
  <text x="616" y="133" text-anchor="middle" fill="#3E5E80" font-size="9">meas tran: 50%→50%</text>
  <text x="616" y="148" text-anchor="middle" fill="#3E5E80" font-size="9">input rise → output rise</text>

  <rect x="542" y="164" width="148" height="56" rx="4" fill="#060C18" stroke="#1A3A5E" stroke-width="1"/>
  <text x="616" y="184" text-anchor="middle" fill="#FB8C00" font-size="11" font-weight="bold">tpd_fall</text>
  <text x="616" y="201" text-anchor="middle" fill="#3E5E80" font-size="9">meas tran: 50%→50%</text>
  <text x="616" y="216" text-anchor="middle" fill="#3E5E80" font-size="9">input fall → output fall</text>

  <rect x="542" y="232" width="148" height="56" rx="4" fill="#060C18" stroke="#1A3A5E" stroke-width="1"/>
  <text x="616" y="252" text-anchor="middle" fill="#FB8C00" font-size="11" font-weight="bold">t_rise / t_fall</text>
  <text x="616" y="269" text-anchor="middle" fill="#3E5E80" font-size="9">output 10%→90%</text>
  <text x="616" y="284" text-anchor="middle" fill="#3E5E80" font-size="9">output 90%→10%</text>

  <rect x="542" y="300" width="148" height="56" rx="4" fill="#060C18" stroke="#1A3A5E" stroke-width="1"/>
  <text x="616" y="320" text-anchor="middle" fill="#FB8C00" font-size="11" font-weight="bold">iavg_rise / iavg_fall</text>
  <text x="616" y="337" text-anchor="middle" fill="#3E5E80" font-size="9">avg I(VDD) in switch</text>
  <text x="616" y="352" text-anchor="middle" fill="#3E5E80" font-size="9">window → pJ energy</text>

  <rect x="542" y="368" width="148" height="56" rx="4" fill="#060C18" stroke="#1A3A5E" stroke-width="1"/>
  <text x="616" y="388" text-anchor="middle" fill="#FB8C00" font-size="11" font-weight="bold">Fallback Values</text>
  <text x="616" y="405" text-anchor="middle" fill="#3E5E80" font-size="9">if ngspice absent or</text>
  <text x="616" y="420" text-anchor="middle" fill="#3E5E80" font-size="9">convergence failure</text>

  <rect x="542" y="436" width="148" height="56" rx="4" fill="#060C18" stroke="#1A3A5E" stroke-width="1"/>
  <text x="616" y="456" text-anchor="middle" fill="#FB8C00" font-size="11" font-weight="bold">Area (GDS)</text>
  <text x="616" y="473" text-anchor="middle" fill="#3E5E80" font-size="9">bbox in db-units²</text>
  <text x="616" y="488" text-anchor="middle" fill="#3E5E80" font-size="9">× db_unit_um² → µm²</text>

  <!-- Arrow: Measurement → Output -->
  <line x1="706" y1="300" x2="754" y2="300" stroke="#43A047" stroke-width="2" marker-end="url(#arrg)"/>

  <!-- Stage 4: Output -->
  <rect x="754" y="60" width="130" height="480" rx="8" fill="#09111F" stroke="#14263E" stroke-width="1.5"/>
  <text x="819" y="85" text-anchor="middle" fill="#B8D0E8" font-size="12" font-weight="bold">OUTPUT</text>

  <rect x="768" y="96" width="100" height="56" rx="4" fill="#060C18" stroke="#1A5080" stroke-width="1"/>
  <text x="818" y="116" text-anchor="middle" fill="#43A047" font-size="11" font-weight="bold">NldmTable</text>
  <text x="818" y="133" text-anchor="middle" fill="#3E5E80" font-size="9">7×7 grid</text>
  <text x="818" y="148" text-anchor="middle" fill="#3E5E80" font-size="9">cell_rise/fall</text>

  <rect x="768" y="164" width="100" height="56" rx="4" fill="#060C18" stroke="#1A5080" stroke-width="1"/>
  <text x="818" y="184" text-anchor="middle" fill="#43A047" font-size="11" font-weight="bold">NldmTable</text>
  <text x="818" y="201" text-anchor="middle" fill="#3E5E80" font-size="9">7×7 grid</text>
  <text x="818" y="216" text-anchor="middle" fill="#3E5E80" font-size="9">rise/fall transition</text>

  <rect x="768" y="232" width="100" height="56" rx="4" fill="#060C18" stroke="#1A5080" stroke-width="1"/>
  <text x="818" y="252" text-anchor="middle" fill="#43A047" font-size="11" font-weight="bold">NldmTable</text>
  <text x="818" y="269" text-anchor="middle" fill="#3E5E80" font-size="9">7×7 grid</text>
  <text x="818" y="284" text-anchor="middle" fill="#3E5E80" font-size="9">rise/fall power</text>

  <rect x="768" y="300" width="100" height="56" rx="4" fill="#060C18" stroke="#1A5080" stroke-width="1"/>
  <text x="818" y="320" text-anchor="middle" fill="#43A047" font-size="11" font-weight="bold">LibertyCell</text>
  <text x="818" y="337" text-anchor="middle" fill="#3E5E80" font-size="9">area, leakage</text>
  <text x="818" y="352" text-anchor="middle" fill="#3E5E80" font-size="9">pins, pg_pins</text>

  <rect x="768" y="368" width="100" height="56" rx="4" fill="#060C18" stroke="#1A5080" stroke-width="1"/>
  <text x="818" y="388" text-anchor="middle" fill="#43A047" font-size="11" font-weight="bold">.lib text</text>
  <text x="818" y="405" text-anchor="middle" fill="#3E5E80" font-size="9">writer.writeLiberty</text>
  <text x="818" y="420" text-anchor="middle" fill="#3E5E80" font-size="9">→ Liberty format</text>

  <rect x="768" y="436" width="100" height="56" rx="4" fill="#060C18" stroke="#1A5080" stroke-width="1"/>
  <text x="818" y="456" text-anchor="middle" fill="#43A047" font-size="11" font-weight="bold">PVT file set</text>
  <text x="818" y="473" text-anchor="middle" fill="#3E5E80" font-size="9">45 .lib files</text>
  <text x="818" y="488" text-anchor="middle" fill="#3E5E80" font-size="9">sky130 corners</text>

  <!-- Stage labels at bottom -->
  <text x="120" y="560" text-anchor="middle" fill="#3E5E80" font-size="10">① Inputs</text>
  <text x="373" y="560" text-anchor="middle" fill="#3E5E80" font-size="10">② Simulation (ngspice)</text>
  <text x="616" y="560" text-anchor="middle" fill="#3E5E80" font-size="10">③ Measurement</text>
  <text x="819" y="560" text-anchor="middle" fill="#3E5E80" font-size="10">④ Liberty Output</text>

  <!-- Status note -->
  <text x="450" y="594" text-anchor="middle" fill="#EF5350" font-size="10">Note: simulation steps require ngspice on PATH; graceful fallback to placeholder values when absent</text>
</svg>
```
