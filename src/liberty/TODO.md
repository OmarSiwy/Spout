### Liberty Generation TODO

#### Volare PDK Corner Support

Expand `CornerSpec` / `sky130_corners` to support any volare-managed PDK, not just sky130.

- [ ] Parse volare PDK directory structure to discover available corners
  - Volare stores corners under `<pdk_root>/libs.tech/ngspice/` with model files per corner
  - Detect PDK variant from directory name (sky130, gf180mcu, etc.)
- [ ] Auto-discover model lib paths from volare install
  - `$PDK_ROOT/<pdk>/libs.tech/ngspice/<corner>.spice`
  - sky130: `sky130.lib.spice` with sections tt/ss/ff/sf/fs
  - gf180mcu: separate files per corner (`sm141064.ngspice` etc.)
- [ ] Build corner list dynamically per PDK
  - sky130: tt/ss/ff/sf/fs × voltages (1.60/1.80/1.95) × temps (-40/25/100)
  - gf180mcu: typical/slow/fast × voltages (3.0/3.3/3.6 for 3v3, 1.62/1.80/1.98 for 1v8)
- [ ] Add `PdkCornerSet` struct that bundles PDK-specific info
  - Model lib path, corner section names, nom voltages, temp ranges
  - Pin naming conventions (sky130: VPWR/VGND/VPB/VNB, gf180: VDD/VSS)
- [ ] Add `LibertyConfig.fromVolare(pdk_root, pdk_name, corner_name)` constructor
- [ ] Support `$PDK_ROOT` env var and `$PDK` for auto-detection

#### ADC Liberty Validation: Frequency Sweep Comparison

Validate Liberty timing accuracy against actual SPICE transient sweeps using an ADC test cell.

- [ ] Build or find a small ADC cell (e.g. flash ADC, SAR ADC) in sky130
  - Could use an existing open-source design (OpenFASoC, FASOC, etc.)
  - Or build a minimal 3-bit flash ADC from comparators
- [ ] Write a frequency sweep testbench in ngspice
  - Sweep input sine wave frequency: 100kHz → 100MHz (log steps)
  - Measure propagation delay (input threshold → output valid) at each freq
  - Measure power consumption at each frequency point
  - Record output transition times (slew) at each frequency
- [ ] Generate Liberty file for same ADC cell using our characterization flow
- [ ] Write comparison script/test
  - [ ] Extract delay from Liberty NLDM tables at matching slew/load conditions
  - [ ] Interpolate Liberty tables to match sweep conditions (bilinear interp)
  - [ ] Compare Liberty-predicted delay vs SPICE-measured delay at each freq point
  - [ ] Plot error vs frequency: expect <15% for low-freq, degrading at high-freq
  - [ ] Compare power: Liberty internal_power vs SPICE measured per-transition energy
- [ ] Define pass/fail criteria
  - Delay error < 20% across 80% of frequency range
  - Power error < 30% (Liberty is point-estimate, SPICE is continuous)
  - Transition time error < 25%
- [ ] Add as integration test (requires ngspice, skip if unavailable)
  - `tests/liberty/test_adc_validation.zig` or Python script
  - Generate Liberty → parse back → compare against golden SPICE data
- [ ] Store golden SPICE sweep results as reference data in `tests/liberty/golden/`

#### Completed
- [x] `pg_pin` groups for power pins (VDD/VSS with pg_type + voltage_name)
- [x] `pg_pin` well-bias pins (VPB/VNB as nwell/pwell)
- [x] `related_power_pin` / `related_ground_pin` in timing arcs
- [x] `related_pg_pin` in internal_power groups
- [x] Multi-corner characterization (ss/tt/ff) via `CornerSpec` + `applyCorner`
- [x] `voltage_map` at library level
- [x] NLDM 2D tables (7x7 slew x load) replacing scalar values
- [x] `lu_table_template` definitions at library level
- [x] NLDM table size: configurable NxM (asymmetric) with flat heap-allocated storage
