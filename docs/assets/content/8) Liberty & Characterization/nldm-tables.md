# NLDM Tables — Non-Linear Delay Model

NLDM (Non-Linear Delay Model) is the standard characterization model used in Liberty `.lib` files for digital and mixed-signal standard cells. It expresses cell propagation delay and output transition time as a two-dimensional function of input slew rate and output load capacitance. The model is non-linear because the mapping from (slew, load) to delay is captured as a lookup table with bilinear interpolation — not a polynomial or RC formula.

---

## Mathematical Model

For any timing metric `D` (cell_rise, cell_fall, rise_transition, or fall_transition):

```
D = f(input_slew, output_load)
```

where `f` is defined by a discrete 2D table. The table has:
- **Rows**: indexed by `input_net_transition` (input slew rate, ns)
- **Columns**: indexed by `total_output_net_capacitance` (output load, pF)

At a query point `(s, l)` that does not exactly match a table entry, the value is computed by **bilinear interpolation** using the four surrounding table entries.

---

## Table Types

Spout generates four timing tables and two power tables per timing arc:

### Timing Tables

| Table name | Units | Measurement |
|---|---|---|
| `cell_rise` | ns | Propagation delay from input crossing 50% to output crossing 50% on a rising output transition |
| `cell_fall` | ns | Propagation delay from input crossing 50% to output crossing 50% on a falling output transition |
| `rise_transition` | ns | Output waveform rise time from 10% to 90% of VDD |
| `fall_transition` | ns | Output waveform fall time from 90% to 10% of VDD |

### Power Tables

| Table name | Units | Measurement |
|---|---|---|
| `rise_power` | pJ | Energy consumed from VDD supply during a rising output transition |
| `fall_power` | pJ | Energy consumed from VDD supply during a falling output transition |

---

## Table Index Breakpoints

Breakpoints are chosen to cover the realistic range of input slews and output loads for a given process. Spout uses logarithmically spaced breakpoints calibrated for sky130:

### Default Slew Breakpoints (ns) — `default_slew_indices`

```
0.0100, 0.0230, 0.0531, 0.1233, 0.2830, 0.6497, 1.5000
```

These span from fast (10 ps) to slow (1.5 ns) input transitions. The spacing is approximately geometric (ratio ~2.3×), providing good resolution across decades.

### Default Load Breakpoints (pF) — `default_load_indices`

```
0.0005, 0.0012, 0.0030, 0.0074, 0.0181, 0.0445, 0.1093
```

These span from 0.5 fF (intrinsic gate input) to 109.3 fF (a lightly-loaded wire), again at approximately geometric spacing (~2.45×).

The default table is 7 × 7 = 49 entries per table. All four timing tables and two power tables share the same breakpoints, declared once in the `lu_table_template` groups in the library header.

Custom breakpoints can be specified via `LibertyConfig.slew_indices` and `LibertyConfig.load_indices`. The template name reflects the dimensions: a 5 × 9 grid produces `delay_template_5x9`.

---

## Table Construction in Spout

Spout computes NLDM table values through direct ngspice transient simulation. This is the most accurate approach (actual SPICE-level waveforms), as opposed to analytical models or look-up from pre-characterized standard cell libraries.

### Sweep Loop

For each timing arc (input pin → output pin), `measureTimingArc` in `spice_sim.zig` runs the full cross-product sweep:

```
for each slew_index[si] in slew_indices:
  for each load_index[li] in load_indices:
    pt = measureSinglePoint(input_pin, output_pin, slew_ns, load_pf)
    cell_rise[si][li]         = pt.tpd_rise_ns
    cell_fall[si][li]         = pt.tpd_fall_ns
    rise_transition[si][li]   = pt.t_rise_ns
    fall_transition[si][li]   = pt.t_fall_ns
    rise_power[si][li]        = pt.rise_pj
    fall_power[si][li]        = pt.fall_pj
```

For the default 7 × 7 grid this is 49 ngspice invocations per arc. For a cell with 2 input pins and 1 output pin, that is 98 simulations total.

### Single-Point Measurement (`measureSinglePoint`)

Each grid point invokes ngspice in batch mode (`ngspice -b`) with a generated testbench deck:

**Testbench structure:**
1. `.lib "{model_lib_path}" {model_corner}` — includes the PDK SPICE models
2. The cell's `.subckt` netlist (embedded verbatim)
3. `xdut` — instantiates the DUT with all ports connected to named nets
4. `vvdd {vdd_net} 0 dc {nom_voltage}` — supply voltage source
5. `vvss {vss_net} 0 dc 0` — ground source
6. Well-bias sources: nwell pins → VDD, pwell pins → VSS
7. `vpulse {input_pin} 0 pulse(0 VDD delay slew_ns slew_ns half_period period)` — input stimulus
8. Mid-rail biases for non-driven signal inputs: `v_bias_{name} {name} 0 dc {VDD/2}`
9. `cload {output_pin} 0 {load_pf}p` — output load capacitor

**Simulation parameters:**
- Transient step: `sim_time_ns / 10000` (default: 5 ps steps for 50 ns window)
- Total simulation time: `sim_time_ns` (default: 50 ns)
- Pulse period: `sim_time_ns`, half-period: `sim_time_ns / 4`

**Measurement commands:**
```spice
meas tran tpd_rise trig v(input) val=VDD*0.5 rise=1 targ v(output) val=VDD*0.5 rise=1
meas tran tpd_fall trig v(input) val=VDD*0.5 fall=1 targ v(output) val=VDD*0.5 fall=1
meas tran t_rise   trig v(output) val=VDD*0.1 rise=1 targ v(output) val=VDD*0.9 rise=1
meas tran t_fall   trig v(output) val=VDD*0.9 fall=1 targ v(output) val=VDD*0.1 fall=1
meas tran iavg_rise avg i(vvdd) from=T_rise_start to=T_rise_end
meas tran iavg_fall avg i(vvdd) from=T_fall_start to=T_fall_end
```

Thresholds:
- Propagation delay: 50% of VDD crossing (input trigger → output trigger)
- Rise transition: 10% → 90% of VDD
- Fall transition: 90% → 10% of VDD
- Power: average supply current during switching interval

**Power calculation:**
```
rise_pj = VDD * iavg_rise * (slew_ns * 2) * 1e-9 * 1e12
fall_pj = VDD * iavg_fall * (slew_ns * 2) * 1e-9 * 1e12
```

**Output parsing:**
ngspice `.measure` results are echoed as `MEAS_TPD_RISE=1.234e-10` etc. `parseNamedValue` scans stdout for each key and parses the float. If a measurement key is absent (convergence failure), `parseMeasureWithFallback` logs a warning and substitutes a conservative fallback value (1 ns for delays, 1 pF for capacitances).

### Input Capacitance Measurement (`measureInputCap`)

For each input pin, an AC analysis at 1 MHz is run:
- AC source `vac {pin} 0 dc {VDD/2} ac 1` applied to the pin
- Other inputs biased at mid-rail
- AC simulation: `ac dec 1 1e6 1e6`
- Measurement: `cin = 1 / (2π × 1MHz × imag(1/i(vac)))`
- Result converted from farads to picofarads
- Fallback: 5 fF if measurement fails

---

## Bilinear Interpolation

When a timing analysis tool queries a delay at a point `(s, l)` not directly in the table, it performs bilinear interpolation. Given the four surrounding table entries:

```
    l0           l1
s0  D(s0,l0)    D(s0,l1)
s1  D(s1,l0)    D(s1,l1)
```

for a query at `(s, l)` where `s0 ≤ s ≤ s1` and `l0 ≤ l ≤ l1`:

```
t = (s - s0) / (s1 - s0)   ← fractional position along slew axis
u = (l - l0) / (l1 - l0)   ← fractional position along load axis

D(s,l) = (1-t)(1-u)·D(s0,l0) + t(1-u)·D(s1,l0)
        + (1-t)u·D(s0,l1)  + t·u·D(s1,l1)
```

This is standard bilinear interpolation — linear along each axis independently, and at the boundary exactly reproducing the table value. The formula can also be written as two linear interpolations:

```
D_low  = D(s0,l0) + u·(D(s0,l1) - D(s0,l0))   ← interpolate at slew=s0
D_high = D(s1,l0) + u·(D(s1,l1) - D(s1,l0))   ← interpolate at slew=s1
D(s,l) = D_low + t·(D_high - D_low)             ← interpolate between slew rows
```

If the query point is outside the table range, tools typically clamp to the nearest edge or extrapolate linearly — behaviour varies by tool.

---

## Timing Arc Types

Spout's `TimingType` enum maps directly to Liberty `timing_type` values:

| Enum value | Liberty string | Used for |
|---|---|---|
| `combinational` | `combinational` | Standard combinational paths (INV, AND, OPA amp output) |
| `rising_edge` | `rising_edge` | Sequential elements: setup/hold around rising clock |
| `falling_edge` | `falling_edge` | Sequential elements: setup/hold around falling clock |
| `setup_rising` | `setup_rising` | Setup constraint for data relative to rising clock |
| `setup_falling` | `setup_falling` | Setup constraint for data relative to falling clock |
| `hold_rising` | `hold_rising` | Hold constraint for data relative to rising clock |
| `hold_falling` | `hold_falling` | Hold constraint for data relative to falling clock |

Currently Spout's SPICE characterization only generates `combinational` arcs (all measured arcs use `timing_type = .combinational`). Sequential arc types are defined in the type system for future use.

---

## Timing Sense

Spout's `TimingSense` enum:

| Enum value | Liberty string | Meaning |
|---|---|---|
| `positive_unate` | `positive_unate` | Output rises when input rises (buffer-like) |
| `negative_unate` | `negative_unate` | Output falls when input rises (inverter-like) |
| `non_unate` | `non_unate` | No monotone relationship (XOR-like, or unknown) |

Timing sense is inferred heuristically by `inferTimingSense` in `writer.zig`: if the SPICE netlist text contains `"inv"`, `"INV"`, or `"Inv"` (case variants), the arc is marked `negative_unate`; otherwise `non_unate` is used as a conservative safe default. Full topology tracing for arbitrary combinational functions is a planned enhancement.

---

## Storing Tables: `NldmTable` in Memory

In Spout's Zig data model, each table is a `NldmTable` struct with a flat `[]f64` array in **row-major order**:

```
index = row * cols + col
      = slew_index * load_count + load_index
```

So `values[0]` through `values[cols-1]` are the first row (fastest slew, all loads), `values[cols]` through `values[2*cols-1]` are the second row, and so on.

Accessed via:
```zig
pub fn get(self: NldmTable, row: usize, col: usize) f64 {
    return self.values[row * self.cols + col];
}
```

Memory is heap-allocated. Each table must be `deinit`-ed separately by the caller.

---

## Handling Missing Values

When ngspice fails to converge for a grid point (e.g. at extreme slew + maximum load), `parseMeasureWithFallback` logs a warning and substitutes a fallback:

| Measurement | Fallback value | Rationale |
|---|---|---|
| `MEAS_TPD_RISE` / `MEAS_TPD_FALL` | 1.0 ns | Conservative delay assumption |
| `MEAS_T_RISE` / `MEAS_T_FALL` | 0.1 ns | Conservative transition assumption |
| `MEAS_IAVG_RISE` / `MEAS_IAVG_FALL` | 1.0 µA | Low but non-zero current |
| `MEAS_LEAK` | 1 pA | Very low leakage |
| `MEAS_CIN` | 5 fF | Typical gate cap |

The fallback mechanism ensures the Liberty file is always written with valid numeric data, even when individual SPICE simulations fail. Tools downstream will still converge, though accuracy suffers for the affected corner of the table.

---

## NLDM vs. CCS

Liberty also supports CCS (Composite Current Source) models, which capture the output current waveform shape rather than just delay and transition times, enabling more accurate crosstalk analysis. Spout currently generates NLDM only. The `delay_model : table_lookup` declaration in the library header selects NLDM. CCS tables would use `delay_model : ccs` and require additional `output_current_*` table groups per pin — this is a future enhancement.

---

## Bilinear Interpolation Diagram

```svg
<svg viewBox="0 0 900 620" xmlns="http://www.w3.org/2000/svg" font-family="'Inter', 'Segoe UI', sans-serif">
  <rect width="900" height="620" fill="#060C18"/>
  <text x="450" y="36" text-anchor="middle" fill="#00C4E8" font-size="18" font-weight="bold">NLDM Bilinear Interpolation</text>

  <!-- NLDM grid background -->
  <rect x="60" y="60" width="520" height="460" rx="6" fill="#09111F" stroke="#14263E" stroke-width="1.5"/>
  <text x="320" y="82" text-anchor="middle" fill="#B8D0E8" font-size="12">NLDM Table: delay = f(input_slew, output_load)</text>

  <!-- Axis labels -->
  <text x="320" y="540" text-anchor="middle" fill="#B8D0E8" font-size="12">input_slew (ns) →</text>
  <text x="80" y="300" text-anchor="middle" fill="#B8D0E8" font-size="12" transform="rotate(-90, 80, 300)">output_load (pF) →</text>

  <!-- Grid: 7 cols × 7 rows, colors by delay value (dark=low, bright=high) -->
  <!-- Row/column positions -->
  <!-- cols at x: 120, 185, 250, 315, 380, 445, 510 (spacing 65) -->
  <!-- rows at y: 100, 165, 230, 295, 360, 425, 490 (spacing 65, reversed so load increases downward) -->

  <!-- Color gradient cells: row 0 (lowest load) to row 6 (highest load) -->
  <!-- Delays increase with slew (right) and load (down) -->

  <!-- Row 0 (load=0.0005 pF) — low load, low delay -->
  <rect x="120" y="100" width="55" height="55" fill="#061828" stroke="#0A2030" stroke-width="0.5"/>
  <rect x="185" y="100" width="55" height="55" fill="#072030" stroke="#0A2030" stroke-width="0.5"/>
  <rect x="250" y="100" width="55" height="55" fill="#082840" stroke="#0A2030" stroke-width="0.5"/>
  <rect x="315" y="100" width="55" height="55" fill="#0A3050" stroke="#0A2030" stroke-width="0.5"/>
  <rect x="380" y="100" width="55" height="55" fill="#0C3870" stroke="#0A2030" stroke-width="0.5"/>
  <rect x="445" y="100" width="55" height="55" fill="#0E4090" stroke="#0A2030" stroke-width="0.5"/>
  <rect x="510" y="100" width="55" height="55" fill="#1050B0" stroke="#0A2030" stroke-width="0.5"/>

  <!-- Row 1 -->
  <rect x="120" y="165" width="55" height="55" fill="#072030" stroke="#0A2030" stroke-width="0.5"/>
  <rect x="185" y="165" width="55" height="55" fill="#082838" stroke="#0A2030" stroke-width="0.5"/>
  <rect x="250" y="165" width="55" height="55" fill="#0A3048" stroke="#0A2030" stroke-width="0.5"/>
  <rect x="315" y="165" width="55" height="55" fill="#0C3860" stroke="#0A2030" stroke-width="0.5"/>
  <rect x="380" y="165" width="55" height="55" fill="#0E4080" stroke="#0A2030" stroke-width="0.5"/>
  <rect x="445" y="165" width="55" height="55" fill="#1050A0" stroke="#0A2030" stroke-width="0.5"/>
  <rect x="510" y="165" width="55" height="55" fill="#1260C0" stroke="#0A2030" stroke-width="0.5"/>

  <!-- Row 2 -->
  <rect x="120" y="230" width="55" height="55" fill="#082840" stroke="#0A2030" stroke-width="0.5"/>
  <rect x="185" y="230" width="55" height="55" fill="#0A3050" stroke="#0A2030" stroke-width="0.5"/>
  <rect x="250" y="230" width="55" height="55" fill="#0C3868" stroke="#0A2030" stroke-width="0.5"/>
  <rect x="315" y="230" width="55" height="55" fill="#0E4080" stroke="#0A2030" stroke-width="0.5"/>
  <rect x="380" y="230" width="55" height="55" fill="#1050A0" stroke="#0A2030" stroke-width="0.5"/>
  <rect x="445" y="230" width="55" height="55" fill="#1262C0" stroke="#0A2030" stroke-width="0.5"/>
  <rect x="510" y="230" width="55" height="55" fill="#1470D8" stroke="#0A2030" stroke-width="0.5"/>

  <!-- Row 3 (highlighted — contains query point) -->
  <rect x="120" y="295" width="55" height="55" fill="#0A3050" stroke="#0A2030" stroke-width="0.5"/>
  <rect x="185" y="295" width="55" height="55" fill="#0C3868" stroke="#0A2030" stroke-width="0.5"/>
  <!-- Highlighted cells around query point -->
  <rect x="250" y="295" width="55" height="55" fill="#1262C0" stroke="#00C4E8" stroke-width="2"/>
  <rect x="315" y="295" width="55" height="55" fill="#1472D8" stroke="#00C4E8" stroke-width="2"/>
  <rect x="380" y="295" width="55" height="55" fill="#1888F0" stroke="#0A2030" stroke-width="0.5"/>
  <rect x="445" y="295" width="55" height="55" fill="#1A98FF" stroke="#0A2030" stroke-width="0.5"/>
  <rect x="510" y="295" width="55" height="55" fill="#20AAFF" stroke="#0A2030" stroke-width="0.5"/>

  <!-- Row 4 (highlighted) -->
  <rect x="120" y="360" width="55" height="55" fill="#0C3868" stroke="#0A2030" stroke-width="0.5"/>
  <rect x="185" y="360" width="55" height="55" fill="#0E4080" stroke="#0A2030" stroke-width="0.5"/>
  <!-- Highlighted cells -->
  <rect x="250" y="360" width="55" height="55" fill="#1472D8" stroke="#00C4E8" stroke-width="2"/>
  <rect x="315" y="360" width="55" height="55" fill="#1882F0" stroke="#00C4E8" stroke-width="2"/>
  <rect x="380" y="360" width="55" height="55" fill="#1C96FF" stroke="#0A2030" stroke-width="0.5"/>
  <rect x="445" y="360" width="55" height="55" fill="#22AAFF" stroke="#0A2030" stroke-width="0.5"/>
  <rect x="510" y="360" width="55" height="55" fill="#28BEFF" stroke="#0A2030" stroke-width="0.5"/>

  <!-- Row 5 -->
  <rect x="120" y="425" width="55" height="55" fill="#0E4080" stroke="#0A2030" stroke-width="0.5"/>
  <rect x="185" y="425" width="55" height="55" fill="#1050A0" stroke="#0A2030" stroke-width="0.5"/>
  <rect x="250" y="425" width="55" height="55" fill="#1262C0" stroke="#0A2030" stroke-width="0.5"/>
  <rect x="315" y="425" width="55" height="55" fill="#1882F0" stroke="#0A2030" stroke-width="0.5"/>
  <rect x="380" y="425" width="55" height="55" fill="#20A0FF" stroke="#0A2030" stroke-width="0.5"/>
  <rect x="445" y="425" width="55" height="55" fill="#28BCFF" stroke="#0A2030" stroke-width="0.5"/>
  <rect x="510" y="425" width="55" height="55" fill="#30D0FF" stroke="#0A2030" stroke-width="0.5"/>

  <!-- Row 6 (highest load) -->
  <rect x="120" y="490" width="55" height="55" fill="#1050A0" stroke="#0A2030" stroke-width="0.5"/>
  <rect x="185" y="490" width="55" height="55" fill="#1262C0" stroke="#0A2030" stroke-width="0.5"/>
  <rect x="250" y="490" width="55" height="55" fill="#1470D8" stroke="#0A2030" stroke-width="0.5"/>
  <rect x="315" y="490" width="55" height="55" fill="#1A90FF" stroke="#0A2030" stroke-width="0.5"/>
  <rect x="380" y="490" width="55" height="55" fill="#22AEFF" stroke="#0A2030" stroke-width="0.5"/>
  <rect x="445" y="490" width="55" height="55" fill="#2CC4FF" stroke="#0A2030" stroke-width="0.5"/>
  <rect x="510" y="490" width="55" height="55" fill="#00C4E8" stroke="#0A2030" stroke-width="0.5"/>

  <!-- X-axis slew labels -->
  <text x="147" y="570" text-anchor="middle" fill="#3E5E80" font-size="9">0.010</text>
  <text x="212" y="570" text-anchor="middle" fill="#3E5E80" font-size="9">0.023</text>
  <text x="277" y="570" text-anchor="middle" fill="#3E5E80" font-size="9">0.053</text>
  <text x="342" y="570" text-anchor="middle" fill="#3E5E80" font-size="9">0.123</text>
  <text x="407" y="570" text-anchor="middle" fill="#3E5E80" font-size="9">0.283</text>
  <text x="472" y="570" text-anchor="middle" fill="#3E5E80" font-size="9">0.650</text>
  <text x="537" y="570" text-anchor="middle" fill="#3E5E80" font-size="9">1.500</text>

  <!-- Y-axis load labels -->
  <text x="108" y="130" text-anchor="end" fill="#3E5E80" font-size="9">0.0005</text>
  <text x="108" y="196" text-anchor="end" fill="#3E5E80" font-size="9">0.0012</text>
  <text x="108" y="261" text-anchor="end" fill="#3E5E80" font-size="9">0.0030</text>
  <text x="108" y="326" text-anchor="end" fill="#3E5E80" font-size="9">0.0074</text>
  <text x="108" y="391" text-anchor="end" fill="#3E5E80" font-size="9">0.0181</text>
  <text x="108" y="456" text-anchor="end" fill="#3E5E80" font-size="9">0.0445</text>
  <text x="108" y="521" text-anchor="end" fill="#3E5E80" font-size="9">0.1093</text>

  <!-- Corner labels on highlighted cells -->
  <text x="277" y="327" text-anchor="middle" fill="#B8D0E8" font-size="9">D(s0,l0)</text>
  <text x="342" y="327" text-anchor="middle" fill="#B8D0E8" font-size="9">D(s1,l0)</text>
  <text x="277" y="392" text-anchor="middle" fill="#B8D0E8" font-size="9">D(s0,l1)</text>
  <text x="342" y="392" text-anchor="middle" fill="#B8D0E8" font-size="9">D(s1,l1)</text>

  <!-- Query point marker -->
  <circle cx="317" cy="335" r="7" fill="none" stroke="#EF5350" stroke-width="2"/>
  <circle cx="317" cy="335" r="3" fill="#EF5350"/>
  <text x="330" y="330" fill="#EF5350" font-size="10" font-weight="bold">query (s,l)</text>

  <!-- Interpolation lines -->
  <line x1="120" y1="322" x2="570" y2="322" stroke="#00C4E8" stroke-width="0.8" stroke-dasharray="4,3" opacity="0.5"/>
  <line x1="120" y1="387" x2="570" y2="387" stroke="#00C4E8" stroke-width="0.8" stroke-dasharray="4,3" opacity="0.5"/>
  <line x1="317" y1="100" x2="317" y2="545" stroke="#00C4E8" stroke-width="0.8" stroke-dasharray="4,3" opacity="0.5"/>

  <!-- Formula panel -->
  <rect x="600" y="80" width="280" height="460" rx="8" fill="#09111F" stroke="#14263E" stroke-width="1.5"/>
  <text x="740" y="108" text-anchor="middle" fill="#00C4E8" font-size="13" font-weight="bold">Bilinear Interpolation</text>

  <text x="615" y="135" fill="#B8D0E8" font-size="10">Given 4 surrounding entries:</text>
  <text x="615" y="155" fill="#3E5E80" font-size="10">D(s0,l0)  D(s1,l0)</text>
  <text x="615" y="172" fill="#3E5E80" font-size="10">D(s0,l1)  D(s1,l1)</text>

  <line x1="615" y1="185" x2="868" y2="185" stroke="#14263E" stroke-width="1"/>

  <text x="615" y="205" fill="#B8D0E8" font-size="10">Fractional positions:</text>
  <rect x="615" y="212" width="253" height="42" rx="3" fill="#060C18" stroke="#1A3A5E" stroke-width="1"/>
  <text x="627" y="228" fill="#00C4E8" font-size="10">t = (s − s0) / (s1 − s0)</text>
  <text x="627" y="248" fill="#00C4E8" font-size="10">u = (l − l0) / (l1 − l0)</text>

  <line x1="615" y1="265" x2="868" y2="265" stroke="#14263E" stroke-width="1"/>

  <text x="615" y="285" fill="#B8D0E8" font-size="10">Interpolated delay:</text>
  <rect x="615" y="292" width="253" height="88" rx="3" fill="#060C18" stroke="#1A3A5E" stroke-width="1"/>
  <text x="627" y="312" fill="#43A047" font-size="9">D = (1−t)(1−u)·D(s0,l0)</text>
  <text x="627" y="330" fill="#43A047" font-size="9">  + t(1−u)·D(s1,l0)</text>
  <text x="627" y="348" fill="#43A047" font-size="9">  + (1−t)u·D(s0,l1)</text>
  <text x="627" y="366" fill="#43A047" font-size="9">  + tu·D(s1,l1)</text>

  <line x1="615" y1="392" x2="868" y2="392" stroke="#14263E" stroke-width="1"/>

  <text x="615" y="412" fill="#B8D0E8" font-size="10">Two-step equivalent:</text>
  <rect x="615" y="418" width="253" height="72" rx="3" fill="#060C18" stroke="#1A3A5E" stroke-width="1"/>
  <text x="627" y="436" fill="#AB47BC" font-size="9">D_low  = D(s0,l0) + u·(D(s0,l1)−D(s0,l0))</text>
  <text x="627" y="454" fill="#AB47BC" font-size="9">D_high = D(s1,l0) + u·(D(s1,l1)−D(s1,l0))</text>
  <text x="627" y="472" fill="#AB47BC" font-size="9">D = D_low + t·(D_high − D_low)</text>

  <line x1="615" y1="502" x2="868" y2="502" stroke="#14263E" stroke-width="1"/>

  <text x="615" y="522" fill="#B8D0E8" font-size="10">Table types (all ns or pJ):</text>
  <text x="615" y="540" fill="#3E5E80" font-size="9">• cell_rise / cell_fall — tpd 50%→50%</text>
  <text x="615" y="555" fill="#3E5E80" font-size="9">• rise_transition — 10%→90% output</text>
  <text x="615" y="570" fill="#3E5E80" font-size="9">• fall_transition — 90%→10% output</text>
  <text x="615" y="585" fill="#FB8C00" font-size="9">• rise_power / fall_power — pJ/switch</text>

  <!-- Color legend -->
  <text x="615" y="608" fill="#3E5E80" font-size="9">Color: dark = low delay, bright cyan = high delay</text>
</svg>
```
