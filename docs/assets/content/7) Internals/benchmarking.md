# Benchmarking Documentation

Complete documentation of Spout's benchmark infrastructure, covering `scripts/benchmark.py`, what is measured, how to run benchmarks, and how to interpret results.

---

## Overview

The Spout benchmark runner executes the full layout pipeline on every SPICE netlist in the benchmark fixture directory and produces:

1. A per-circuit phase timing table (all 8 pipeline stages)
2. A bottleneck analysis showing average time per phase with ASCII bar charts
3. Per-circuit signoff results (DRC violation count, LVS pass/fail, parasitic counts)

---

## Benchmark Script: `scripts/benchmark.py`

**Full invocation:**

```bash
# Run all benchmarks
python scripts/benchmark.py

# Run only first 5 (alphabetical)
python scripts/benchmark.py -n 5

# Run specific circuits by name
python scripts/benchmark.py -c current_mirror diff_pair

# Sort output table by routing time
python scripts/benchmark.py --sort route

# Skip PEX (faster runs)
python scripts/benchmark.py --no-pex

# Use a different PDK
python scripts/benchmark.py --pdk gf180
```

---

## Benchmark Discovery

### `collect_benchmarks(root: pathlib.Path) -> list[pathlib.Path]`

Discovers benchmark SPICE files at `<project_root>/fixtures/benchmark/*.spice`, sorted alphabetically.

**Exclusion rule:** Files with `_lvs` or `_pex` in their stem are excluded. These are extraction artifact files (schematic copies used for LVS, or extracted parasitics) not primary benchmark inputs.

```python
def collect_benchmarks(root: pathlib.Path) -> list[pathlib.Path]:
    bm_dir = root / "fixtures" / "benchmark"
    return sorted(
        p for p in bm_dir.glob("*.spice")
        if "_lvs" not in p.stem and "_pex" not in p.stem
    )
```

The `_ROOT` is determined by the script's location: `pathlib.Path(__file__).resolve().parent.parent` (one level up from `scripts/`).

---

## Module Import Bootstrapping

The script bootstraps its own import path before importing `spout`:

```python
_ROOT = pathlib.Path(__file__).resolve().parent.parent
_python_dir = str(_ROOT / "python")
if _python_dir not in sys.path:
    sys.path.insert(0, _python_dir)
```

If `spout` is not already in `sys.modules`, the script registers `python/` as the `spout` package using `importlib.util.spec_from_file_location`. This allows running from any directory without installing the package.

Logging is disabled at CRITICAL level to silence the pipeline logger and render custom output.

---

## Pipeline Phases

The benchmark tracks 8 pipeline phases:

| Key            | Display Label | Stage Description                                          |
| -------------- | ------------- | ---------------------------------------------------------- |
| `parse`        | `Parse`       | SPICE netlist parsing → device/net/pin arrays              |
| `constraints`  | `Constr`      | Constraint extraction (diff pairs, mirrors, cascodes)      |
| `placement`    | `Place`       | Simulated-annealing placement                              |
| `routing`      | `Route`       | Maze routing                                               |
| `export`       | `Export`      | GDSII file generation                                      |
| `drc`          | `DRC`         | KLayout signoff DRC                                        |
| `lvs`          | `LVS`         | KLayout signoff LVS                                        |
| `pex`          | `PEX`         | Magic ext2spice parasitic extraction                       |

---

## Runner

### `run_benchmark(spice: pathlib.Path, cfg: SpoutConfig) -> tuple[PipelineResult, str | None]`

Runs the full pipeline on a single SPICE file using a temporary output directory. Returns `(result, None)` on success, or `(None, error_str)` on exception. The temporary directory (and its GDS output) is deleted after each run.

---

## Collected Metrics

For each benchmark circuit, the following row is collected:

| Field         | Source                       | Description                                      |
| ------------- | ---------------------------- | ------------------------------------------------ |
| `name`        | File stem                    | Circuit name (e.g., `current_mirror`)            |
| `devices`     | `result.num_devices`         | Number of devices in the netlist                 |
| `nets`        | `result.num_nets`            | Number of nets                                   |
| `routes`      | `result.num_routes`          | Number of route segments generated               |
| `parse`       | `timings.parse`              | Parse stage wall time (seconds)                  |
| `constraints` | `timings.constraints`        | Constraint extraction wall time                  |
| `placement`   | `timings.placement`          | SA placement wall time                           |
| `routing`     | `timings.routing`            | Routing wall time                                |
| `export`      | `timings.export`             | GDSII export wall time                           |
| `drc`         | `timings.drc`                | KLayout DRC wall time                            |
| `lvs`         | `timings.lvs`                | KLayout LVS wall time                            |
| `pex`         | `timings.pex`                | Magic PEX wall time                              |
| `total`       | `timings.total`              | Sum of all stage times                           |
| `drc_count`   | `result.drc_violations`      | Number of DRC violations (0 = clean)             |
| `lvs_ok`      | `result.lvs_clean`           | LVS pass/fail (True/False)                       |
| `pex_res`     | `result.pex_parasitic_res`   | Number of extracted resistors                    |
| `pex_cap`     | `result.pex_parasitic_caps`  | Number of extracted capacitors                   |

---

## Output Format

### Progress Line (per circuit)

```
[ 1/ 5] current_mirror ...    42ms  DRC=0  LVS=✓  R=3 C=12
[ 2/ 5] diff_pair ...         89ms  DRC=2  LVS=✗  R=6 C=24
```

### Phase Timing Table

```
==========================================================================================================
PHASE TIMINGS
==========================================================================================================
Circuit         Dev  Net  Rte     Parse   Constr    Place    Route   Export      DRC      LVS      PEX     Total    DRC   LVS  Res    Cap
-------------------------------------------------------------------------------------------------------------------------------------------
current_mirror    2    4    8      1ms      2ms      18ms     12ms     3ms      42ms     31ms     89ms     198ms      0    ✓    3     12
diff_pair         2    6    9      1ms      2ms      22ms     15ms     3ms      45ms     29ms     93ms     210ms      2    ✗    6     24
-------------------------------------------------------------------------------------------------------------------------------------------
AVERAGE                            1ms      2ms      20ms     13ms     3ms      43ms     30ms     91ms     204ms
```

### Bottleneck Analysis

```
============================================================
BOTTLENECK ANALYSIS  (average time per phase)
============================================================
  DRC       43ms   21%  ████████░░░░░░░░░░░░░░░░░░░░░░
  PEX       91ms   45%  ██████████████████████░░░░░░░░
  LVS       30ms   15%  ██████░░░░░░░░░░░░░░░░░░░░░░░░
  Route     13ms    6%  ███░░░░░░░░░░░░░░░░░░░░░░░░░░░
  ...

  Bottleneck: PEX (91ms/circuit avg, 45% of pipeline)
```

---

## Formatting Helpers

### `bar(value: float, total: float, width: int = 20) -> str`

Produces an ASCII bar chart segment using `█` (filled) and `░` (empty) block characters. Handles `total <= 0` gracefully (returns empty bar).

### `fmt_ms(s: float) -> str`

Formats a duration in seconds to a human-readable millisecond string:
- `>= 10,000 ms`: displays as seconds (e.g., `"10.0s"`)
- Otherwise: displays as milliseconds (e.g., `"42ms"`)

### `fmt_pct(part: float, total: float) -> str`

Formats a fraction as a right-aligned 4-character percentage string. Returns `" —"` for zero total.

---

## Command-Line Arguments

| Argument        | Default   | Description                                                              |
| --------------- | --------- | ------------------------------------------------------------------------ |
| `-c`/`--circuits` | all     | Run only circuits with matching stem names                               |
| `-n`/`--limit`  | 0 (all)   | Run at most N benchmarks (alphabetical order)                            |
| `--sort`        | `total`   | Sort table by: `name`, `parse`, `constraints`, `placement`, `routing`, `route` (alias), `export`, `drc`, `lvs`, `pex`, `total`, `drc_count` |
| `--no-pex`      | False     | Skip PEX extraction (faster runs; pex column will be 0)                  |
| `--pdk`         | `sky130`  | PDK to use: `sky130`, `gf180`, `ihp130`                                  |

Note: `--no-pex` is accepted as an argument but not yet wired into the pipeline — the `run_benchmark` function calls `run_pipeline` which always runs PEX. The flag is present for future implementation.

---

## How to Run Benchmarks

### Prerequisites

1. Build the Spout library: `zig build` (produces `python/libspout.so`)
2. Build the Python extension: `zig build pyext` (produces `python/spout.so`)
3. Set `PDK_ROOT` environment variable: `export PDK_ROOT=/path/to/open_pdks`
4. Ensure `klayout` and `magic` are in PATH
5. Have SPICE benchmarks in `fixtures/benchmark/`

### Running

```bash
# From project root
python scripts/benchmark.py

# Specific circuits
python scripts/benchmark.py -c current_mirror differential_pair cascode

# Limit to first 3 circuits, sort by routing time
python scripts/benchmark.py -n 3 --sort route

# Run with GF180MCU PDK
python scripts/benchmark.py --pdk gf180
```

### Interpreting Results

**DRC violations = 0:** Required for tapeout submission. Any non-zero count indicates layout geometry violations that must be fixed.

**LVS ✓:** Layout connectivity matches the schematic. LVS ✗ means the router disconnected a net, added a spurious device, or the extracted netlist has wrong device names/models.

**Parasitic counts:** Higher R and C counts indicate more complex routing parasitics. The PEX count alone does not indicate quality; the `PexAssessment.rating` from `_assess_pex()` provides quality context.

**Bottleneck analysis:** The single most actionable output. Typical bottlenecks:
- **PEX** is typically the largest stage (Magic ext2spice is slow due to subprocess overhead and Magic's extraction time)
- **DRC** is typically second (KLayout DRC rule deck for sky130 is comprehensive)
- **Placement** scales with `max_iterations × devices`
- **Routing** scales with `devices × nets`

**Success rate:** The fraction of circuits that complete with `success=True` (DRC=0 and LVS=✓).

---

## Benchmark Fixture Format

Benchmarks are SPICE netlists in `fixtures/benchmark/`. Expected format:

```spice
* Current mirror
.subckt current_mirror VDD VSS IN OUT
M0 IN  IN  VSS VSS nmos w=4u l=0.5u
M1 OUT IN  VSS VSS nmos w=4u l=0.5u
.ends current_mirror
```

Requirements:
- Must have at least one `.subckt` definition
- The last `.subckt` name becomes the GDSII top cell name
- File stem must not contain `_lvs` or `_pex`

---

## Error Reporting

Circuits that fail (any exception during `run_pipeline()`) are collected separately and printed at the end:

```
FAILED (2):
  broken_circuit: ParseFailed: netlist parse error at line 5
  missing_pdk:    FileNotFoundError: Magic tech file not found: /path/to/sky130A.tech
```

The benchmark exits with code 1 if all benchmarks fail. If some succeed, it exits with code 0 even with failures.

---

## Performance Expectations

Typical runtimes on a modern workstation with sky130A PDK:

| Stage          | Typical Range      | Notes                                            |
| -------------- | ------------------ | ------------------------------------------------ |
| Parse          | 1–10 ms            | SPICE parser is fast                             |
| Constraints    | 1–5 ms             | Graph traversal on small netlists                |
| Placement      | 10–500 ms          | Scales with `max_iterations × devices²`          |
| Routing        | 5–200 ms           | Scales with `nets × routing_area`                |
| Export         | 1–20 ms            | GDSII binary write is fast                       |
| DRC (KLayout)  | 30–120 s           | Dominated by KLayout startup and DRC rule deck   |
| LVS (KLayout)  | 20–90 s            | KLayout LVS includes device extraction           |
| PEX (Magic)    | 30–180 s           | Magic startup + ext2spice for complex circuits   |

The signoff stages (DRC, LVS, PEX) dominate the total benchmark time. The core Spout pipeline (parse + constraints + placement + routing + export) is typically under 1 second for small analog circuits.
