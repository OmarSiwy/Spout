# Python Tools Documentation

Complete documentation of every function and class in the Spout Python layer: `python/tools.py`, `python/main.py`, `python/config.py`, `python/__init__.py`, and `python/tinytapeout.py`.

---

## Module Structure

```
python/
├── __init__.py          # Public API re-exports
├── config.py            # SpoutConfig, SaConfig, MacroDefinition
├── main.py              # run_pipeline(), CLI entry point, dataclasses
├── tools.py             # External signoff tool wrappers (KLayout, Magic)
└── tinytapeout.py       # TinyTapeout-specific convenience wrappers
```

---

## `python/__init__.py` — Public API

The `__init__.py` file defines the public importable API for the `spout` package:

```python
from .config import SpoutConfig as SpoutConfig, SaConfig as SaConfig
from .main import (
    run_pipeline as run_pipeline,
    PipelineResult as PipelineResult,
    TemplateConfig as TemplateConfig,
    LibertyResult as LibertyResult,
    LibertyAllCornersResult as LibertyAllCornersResult,
)
```

All names are explicitly re-exported with the `as Name` pattern, making them appear in type checkers as public exports.

**What is importable from `import spout` (the Python package, not the extension):**
- `SpoutConfig` — pipeline configuration class
- `SaConfig` — SA placer hyperparameters
- `run_pipeline` — main pipeline function
- `PipelineResult` — pipeline output dataclass
- `TemplateConfig` — GDS template configuration dataclass
- `LibertyResult` — single-corner Liberty result dataclass
- `LibertyAllCornersResult` — multi-corner Liberty result dataclass

**What is NOT in `__init__.py` but available via direct import:**
- `spout.tools.run_klayout_drc`, `run_klayout_lvs`, `run_magic_pex` — signoff tool wrappers
- `spout.tinytapeout.run_tinytapeout_pipeline` — TinyTapeout helper
- `spout.main.StageTimings`, `PexAssessment` — detailed result types

---

## `python/config.py` — Configuration

### `_SaConfigC` (internal, ctypes.Structure)

Internal ctypes mirror of the Zig `SaConfig` extern struct (`src/placer/types.zig`). Maps directly to the binary layout expected by `spout_run_sa_placement`. Not for direct use.

```python
class _SaConfigC(ctypes.Structure):
    _fields_ = [
        ("initialTemp",               ctypes.c_float),
        ("coolingRate",               ctypes.c_float),
        ("minTemp",                   ctypes.c_float),
        ("maxIterations",             ctypes.c_uint32),
        ("perturbationRange",         ctypes.c_float),
        ("wHpwl",                     ctypes.c_float),
        ("wArea",                     ctypes.c_float),
        ("wSymmetry",                 ctypes.c_float),
        ("wMatching",                 ctypes.c_float),
        ("wRudy",                     ctypes.c_float),
        ("wOverlap",                  ctypes.c_float),
        ("wThermal",                  ctypes.c_float),
        ("wTiming",                   ctypes.c_float),
        ("wEmbedSimilarity",          ctypes.c_float),
        ("wParasitic",                ctypes.c_float),
        ("adaptiveCooling",           ctypes.c_uint8),
        ("adaptiveWindow",            ctypes.c_uint32),
        ("maxReheats",                ctypes.c_uint32),
        ("reheatFraction",            ctypes.c_float),
        ("stallWindowsBeforeReheat",  ctypes.c_uint32),
        ("numStarts",                 ctypes.c_uint32),
        ("delayDriverR",              ctypes.c_float),
        ("delayWireRPerUm",           ctypes.c_float),
        ("delayWireCPerUm",           ctypes.c_float),
        ("delayPinC",                 ctypes.c_float),
    ]
```

---

### `SaConfig` (dataclass)

Simulated-annealing hyperparameter configuration. Mirrors the Zig `SaConfig` extern struct.

```python
@dataclass
class SaConfig:
    initial_temp: float = 1000.0
    cooling_rate: float = 0.995
    min_temp: float = 0.01
    max_iterations: int = 50_000
    perturbation_range: float = 10.0   # microns
    # Cost-function weights
    w_hpwl: float = 1.0
    w_area: float = 0.5
    w_symmetry: float = 2.0
    w_matching: float = 1.5
    w_rudy: float = 0.3
    w_overlap: float = 100.0
    w_timing: float = 0.3
    w_thermal: float = 0.0
    w_embed_similarity: float = 0.5
    w_parasitic: float = 0.2
    adaptive_cooling: bool = True
    adaptive_window: int = 500
    max_reheats: int = 5
    reheat_fraction: float = 0.3
    stall_windows_before_reheat: int = 3
    num_starts: int = 1
    # Delay estimator parameters
    delay_driver_r: float = 500.0      # Ohm
    delay_wire_r_per_um: float = 0.125 # Ohm/µm
    delay_wire_c_per_um: float = 0.2   # fF/µm
    delay_pin_c: float = 1.0           # fF
```

**SA cost function weights explained:**

| Weight              | Default | Effect                                                                          |
| ------------------- | ------- | ------------------------------------------------------------------------------- |
| `w_hpwl`            | 1.0     | Half-perimeter wirelength — minimize total routing length                        |
| `w_area`            | 0.5     | Minimize total bounding-box area of the placement                                |
| `w_symmetry`        | 2.0     | Penalize asymmetric placement of detected symmetry pairs (diff pairs)            |
| `w_matching`        | 1.5     | Penalize unequal SA/SB for detected matching pairs (current mirrors)             |
| `w_rudy`            | 0.3     | RUDY routing density — penalize congested routing regions                        |
| `w_overlap`         | 100.0   | **Hard overlap penalty** — prevents devices from overlapping (must be large)     |
| `w_timing`          | 0.3     | Elmore delay estimate — minimize critical path delay                             |
| `w_thermal`         | 0.0     | Disabled by default; penalize placement near heat sources when nonzero           |
| `w_embed_similarity`| 0.5     | ML embedding similarity (requires ML write-back to be meaningful)               |
| `w_parasitic`       | 0.2     | Parasitic routing asymmetry estimate                                             |

**SA schedule parameters:**

| Parameter                     | Default  | Effect                                                               |
| ----------------------------- | -------- | -------------------------------------------------------------------- |
| `initial_temp`                | 1000.0   | Starting temperature — higher = more random moves accepted initially |
| `cooling_rate`                | 0.995    | Geometric cooling multiplier per iteration                           |
| `min_temp`                    | 0.01     | Termination temperature — lower = more refined final solution        |
| `max_iterations`              | 50,000   | Hard iteration limit regardless of temperature schedule              |
| `perturbation_range`          | 10.0 µm  | Maximum move distance in a single perturbation                       |
| `adaptive_cooling`            | True     | Dynamically adjust cooling rate based on acceptance rate             |
| `adaptive_window`             | 500      | Iterations window for measuring acceptance rate                      |
| `max_reheats`                 | 5        | Maximum number of reheating events                                   |
| `reheat_fraction`             | 0.3      | Fraction of initial temperature to reheat to                         |
| `stall_windows_before_reheat` | 3        | Number of stall windows before triggering a reheat                   |
| `num_starts`                  | 1        | Number of independent SA restarts (best result is kept)              |

**Delay estimator parameters:**

| Parameter           | Default    | Effect                                                        |
| ------------------- | ---------- | ------------------------------------------------------------- |
| `delay_driver_r`    | 500.0 Ω    | Driver output resistance for Elmore delay computation          |
| `delay_wire_r_per_um` | 0.125 Ω/µm | Metal wire resistance per micron                            |
| `delay_wire_c_per_um` | 0.2 fF/µm  | Metal wire capacitance per micron                           |
| `delay_pin_c`       | 1.0 fF     | Input capacitance at each pin endpoint                        |

**Methods:**

#### `SaConfig.to_json_bytes() -> bytes`

Serializes a subset of SA hyperparameters (initial_temp, cooling_rate, min_temp, max_iterations, perturbation_range, and 5 weights: hpwl, area, symmetry, matching, rudy) to compact UTF-8 JSON bytes. Used for human-readable logging but NOT passed to the Zig placer (which uses `to_ffi_bytes`).

#### `SaConfig.to_ffi_bytes() -> bytes`

Serializes ALL SA hyperparameters to the binary layout of the Zig `SaConfig` C struct. This is the method called by `run_pipeline` to pass configuration to `layout.run_sa_placement()`. Uses `ctypes.Structure` to guarantee correct binary layout, field types, and alignment.

---

### `MacroDefinition` (dataclass)

Represents a user-defined macro for repeated subcircuit layout reuse.

```python
@dataclass
class MacroDefinition:
    name: str = ""
    subcircuit: str = ""
    gds_path: Optional[str] = None
    placement: Optional[dict[str, tuple[float, float]]] = None
```

Provide either `gds_path` (a pre-built GDSII layout) or `placement` (a dict mapping device names to (x, y) positions in microns).

---

### `SpoutConfig`

Top-level pipeline configuration class.

```python
class SpoutConfig:
    BACKENDS = {"magic": 0, "klayout": 1}
    PDKS = {"sky130": 0, "gf180": 1, "ihp130": 2}
    _PDK_VARIANTS = {
        "sky130": "sky130A",
        "gf180": "gf180mcuD",
        "ihp130": "ihp-sg13g2",
    }
    _TECH_FILES = {
        ("magic", "sky130"): "libs.tech/magic/sky130A.tech",
        ("magic", "gf180"): "libs.tech/magic/gf180mcuD.tech",
        ("magic", "ihp130"): "libs.tech/magic/ihp-sg13g2.tech",
        ("klayout", "sky130"): "libs.tech/klayout/sky130A.lyt",
        ("klayout", "gf180"): "libs.tech/klayout/gf180mcuD.lyt",
        ("klayout", "ihp130"): "libs.tech/klayout/ihp-sg13g2.lyt",
    }
```

**Constructor parameters:**

| Parameter               | Type                        | Default          | Effect                                                    |
| ----------------------- | --------------------------- | ---------------- | --------------------------------------------------------- |
| `backend`               | `str`                       | `"magic"`        | Layout backend: `"magic"` or `"klayout"`                  |
| `pdk`                   | `str`                       | `"sky130"`       | PDK: `"sky130"`, `"gf180"`, or `"ihp130"`                |
| `use_moead_placement`   | `bool`                      | `False`          | Prefer MOEA/D placement entrypoint when available         |
| `use_detailed_routing`  | `bool`                      | `False`          | Prefer detailed routing entrypoint when available         |
| `pdk_root`              | `Optional[str]`             | `None`           | PDK installation root; falls back to `$PDK_ROOT`         |
| `sa_config`             | `Optional[SaConfig]`        | `None`           | SA hyperparameters; defaults to `SaConfig()`             |
| `output_dir`            | `str`                       | `"spout_output"` | Directory for intermediate and final output files        |
| `macros`                | `list[MacroDefinition]|None` | `None`           | User-defined macros for repeated subcircuit layout reuse |

Raises `ValueError` for unknown backend or PDK.

**Properties:**

#### `SpoutConfig.pdk_variant_root -> str`

Absolute path to the PDK variant directory. Example: `$PDK_ROOT/sky130A` for sky130.

#### `SpoutConfig.tech_file -> str`

Absolute path to the tech file for the chosen (backend, pdk) combination. Example: `$PDK_ROOT/sky130A/libs.tech/magic/sky130A.tech` for magic+sky130.

**Attributes set during construction:**
- `self.backend: str` — "magic" or "klayout"
- `self.pdk: str` — "sky130", "gf180", or "ihp130"
- `self.backend_id: int` — integer ID for FFI (magic=0, klayout=1)
- `self.pdk_id: int` — integer ID for FFI (sky130=0, gf180=1, ihp130=2)
- `self.use_moead_placement: bool`
- `self.use_detailed_routing: bool`
- `self.pdk_root: str` — resolved PDK root path
- `self.sa_config: SaConfig`
- `self.output_dir: str`
- `self.macros: list[MacroDefinition]`

---

## `python/main.py` — Pipeline

### `TemplateConfig` (dataclass)

Configuration for GDS template integration (e.g., TinyTapeout).

```python
@dataclass
class TemplateConfig:
    gds_path: str
    cell_name: Optional[str] = None
    user_area_origin: tuple = (0.0, 0.0)
```

- `gds_path`: Path to the GDS template file (e.g., TinyTapeout wrapper GDS).
- `cell_name`: Cell name to use as the user area. When `None`, the largest cell in the template is selected automatically.
- `user_area_origin`: `(x, y)` in microns where the user circuit is placed inside the template's user area. `(0.0, 0.0)` means the origin of the user area.

---

### `StageTimings` (dataclass)

Wall-clock seconds for each pipeline stage.

```python
@dataclass
class StageTimings:
    parse: float = 0.0
    constraints: float = 0.0
    placement: float = 0.0
    routing: float = 0.0
    export: float = 0.0
    drc: float = 0.0
    lvs: float = 0.0
    pex: float = 0.0
```

**Property:** `total -> float` — sum of all stage timings using `dataclasses.fields`.

---

### `PexAssessment` (dataclass)

Quality assessment of parasitic extraction results.

```python
@dataclass
class PexAssessment:
    rating: str  # "unknown", "excellent", "good", "acceptable", "poor", "broken"
    total_res_ohm: float = 0.0
    total_cap_ff: float = 0.0
    max_res_ohm: float = 0.0
    max_res_layer: str = ""
    notes: list[str] = field(default_factory=list)
```

**Rating thresholds** (from `_assess_pex()`):
- `"broken"`: `total_res_ohm > 500` OR `total_cap_ff > 1000`
- `"poor"`: `total_res_ohm > 200` OR `total_cap_ff > 500`
- `"acceptable"`: `total_res_ohm > 50` OR `total_cap_ff > 100`
- `"excellent"`: `total_res_ohm < 15` AND `total_cap_ff < 1`
- `"good"`: otherwise
- `"unknown"`: no parasitics extracted (both counts are 0)

---

### `PipelineResult` (dataclass)

Aggregated outcome of a complete Spout2 pipeline run.

```python
@dataclass
class PipelineResult:
    gds_path: str
    drc_violations: int
    lvs_clean: bool
    success: bool
    error: Optional[str] = None
    placement_cost: float = 0.0
    num_devices: int = 0
    num_nets: int = 0
    num_routes: int = 0
    pex_parasitic_caps: int = 0
    pex_parasitic_res: int = 0
    pex_assessment: Optional[PexAssessment] = None
    timings: StageTimings = field(default_factory=StageTimings)
```

`success = True` iff `drc_violations == 0 AND lvs_clean`.

On exception, returns with `success=False`, `drc_violations=-1`, `lvs_clean=False`, and `error=str(exc)`.

---

### `LibertyResult` (dataclass)

Result of a single-corner Liberty file generation.

```python
@dataclass
class LibertyResult:
    output_path: str
    corner: str
```

---

### `LibertyAllCornersResult` (dataclass)

Result of all-corners Liberty file generation.

```python
@dataclass
class LibertyAllCornersResult:
    num_files: int
    output_dir: str
```

---

### `_timed(fn, *args, **kwargs) -> tuple[result, float]`

Internal helper. Calls `fn(*args, **kwargs)` and returns `(result, elapsed_seconds)` using `time.monotonic()`. Used to populate `StageTimings` fields for each pipeline stage.

---

### `_extract_subckt_name(netlist_path: str) -> str`

Extracts the last `.subckt` name from a SPICE netlist file. Returns empty string on error. Used to determine the GDSII cell name from the input netlist.

Pattern: `re.match(r"\.subckt\s+(\S+)", line, re.IGNORECASE)` — takes the **last** match (a netlist with multiple subcircuits will use the outermost/last-defined one).

---

### `_run_placement_stage(layout, config, config_bytes) -> tuple[str, float]`

Runs simulated-annealing placement. Returns `("sa", elapsed_seconds)`. Always runs SA placement regardless of `config.use_moead_placement` (MOEA/D placement entrypoint not yet wired up to a separate code path).

---

### `_run_routing_stage(layout, config) -> tuple[str, float]`

Runs routing. Returns `("maze", elapsed_seconds)`. Always runs maze routing regardless of `config.use_detailed_routing` (detailed routing not yet a separate pipeline stage).

---

### `_assess_pex(num_caps, num_res, total_cap_ff, total_res_ohm) -> Optional[PexAssessment]`

Produces a `PexAssessment` from aggregate PEX counts and totals. Returns `PexAssessment(rating="unknown")` when both counts are zero. Generates human-readable notes about high/low parasitic values.

---

### `run_pipeline(netlist_path, config, output_path, layout, template_config) -> PipelineResult`

**The main entry point for the entire Spout layout automation pipeline.**

```python
def run_pipeline(
    netlist_path: str,
    config: SpoutConfig,
    output_path: str = "output.gds",
    layout: Optional[_spout.Layout] = None,
    template_config: Optional[TemplateConfig] = None,
) -> PipelineResult:
```

**Parameters:**
- `netlist_path`: Path to a SPICE netlist (`.spice`, `.sp`, `.cdl`)
- `config`: Pipeline configuration
- `output_path`: Destination path for GDSII output
- `layout`: Pre-initialized `spout.Layout` handle; a fresh one is created when `None`
- `template_config`: Optional GDS template; when provided, layout is constrained to the template's user area

**Pipeline stages (in order):**

1. **Parse** (`layout.parse_netlist(netlist_path)`) — populates device/net/pin arrays
2. **Constraints** (`layout.extract_constraints()`) — detects diff pairs, mirrors, cascodes
3. **(Optional) Template** (`layout.load_template_gds(...)`) — loads GDS template and queries bounds
4. **Placement** (`layout.run_sa_placement(config.sa_config.to_ffi_bytes())`) — SA placer
5. **Routing** (`layout.run_routing()`) — maze router
6. **Export** — either `layout.export_gdsii_named(...)` or `layout.export_gdsii_with_template(...)`
7. **DRC** (`tools.run_klayout_drc(output_path, cell_for_signoff)`) — KLayout DRC
8. **LVS** (`tools.run_klayout_lvs(output_path, netlist_path, cell_for_signoff)`) — KLayout LVS
9. **PEX** (`tools.run_magic_pex(output_path, cell_for_signoff, tmp_dir)`) — Magic ext2spice

**Output directory:** Created automatically via `os.makedirs(out_dir, exist_ok=True)`.

**Error handling:** All exceptions are caught, logged, and returned in `PipelineResult.error`. The layout handle is always destroyed in the `finally` block when created internally.

**Success condition:** `drc_violations == 0 AND lvs_clean`.

---

### `_cmd_run(args: argparse.Namespace) -> None`

CLI handler for the `run` subcommand. Constructs `SpoutConfig` and optionally `TemplateConfig` from `args`, calls `run_pipeline()`, and prints a formatted results table to stdout. Exits with code 0 on success, 1 on failure.

---

### `_cmd_liberty(args: argparse.Namespace) -> None`

CLI handler for the `liberty` subcommand. Validates that `ngspice` is in PATH. Calls either:
- `_spout.liberty_generate(gds, spice, cell_name, pdk_id, corner, output)` for a single corner
- `_spout.liberty_generate_all_corners(gds, spice, cell_name, pdk_id, output_dir)` for all corners

Prints generated file paths to stdout.

---

### `main() -> None`

CLI entry point. Called by `python -m python run ...` or `python -m python liberty ...`.

**Subcommands:**

**`run` subcommand:**

| Argument              | Default       | Description                                              |
| --------------------- | ------------- | -------------------------------------------------------- |
| `netlist`             | (required)    | Path to SPICE netlist                                    |
| `-o` / `--output`     | `output.gds`  | Output GDSII path                                        |
| `-p` / `--pdk`        | `sky130`      | PDK: `sky130`, `gf180`, `ihp130`                         |
| `--moead`             | False         | Use MOEA/D placement when available                      |
| `--detailed-routing`  | False         | Use detailed routing when available                      |
| `--pdk-root`          | None          | PDK root directory path                                  |
| `--template-gds`      | None          | Path to GDS template file                                |
| `--template-cell`     | None          | Cell name within template (auto-detect if omitted)       |
| `-v` / `--verbose`    | False         | Enable DEBUG logging                                     |

**`liberty` subcommand:**

| Argument              | Default               | Description                                   |
| --------------------- | --------------------- | --------------------------------------------- |
| `gds`                 | (required)            | Input GDS file path                           |
| `spice`               | (required)            | Input SPICE netlist path                      |
| `--cell-name` / `-c`  | (required)            | Cell name (must match .subckt in SPICE)       |
| `--pdk`               | `sky130`              | PDK: `sky130`, `gf180`, `gf180mcu`, `ihp130` |
| `--corner`            | `tt_025C_1v80`        | Corner name (single-corner mode)              |
| `--all-corners` / `-a`| False                 | Generate for all PVT corners                  |
| `--output` / `-o`     | `{cell}_{corner}.lib` | Output .lib path (single corner)              |
| `--output-dir`        | None                  | Output directory (--all-corners mode)         |

---

## `python/tools.py` — Signoff Tool Wrappers

This module wraps external EDA tools (KLayout, Magic) for signoff verification. All functions are pure Python with subprocess calls.

### `run_klayout_drc(gds_path: str, top_cell: str) -> int`

Run KLayout DRC on a GDS file. Returns violation count.

**Environment dependency:** `$PDK_ROOT` environment variable must point to the PDK installation root.

**DRC script path:** `$PDK_ROOT/sky130A/libs.tech/klayout/drc/sky130A.lydrc`

**Command constructed:**
```
klayout -b -r <drc_script>
        -rd input=<gds_path>
        -rd topcell=<top_cell>
        -rd report=<tmpdir>/klayout_drc_report.lyrdb
```

**Timeout:** 120 seconds.

**Result parsing:** The `.lyrdb` file is XML. The function counts all `<item>` elements inside all `<items>` elements inside all `<category>` elements. Each item is one DRC violation.

**Error conditions:**
- `FileNotFoundError` if the KLayout DRC script is not found
- `RuntimeError` if KLayout returns a non-zero exit code
- `RuntimeError` if no report file is produced
- `RuntimeError` with parse error message if the XML is malformed

---

### `_SKY130_MODEL_MAP` (module-level dict)

Maps generic MOSFET model names to sky130 KLayout-recognized names:

```python
_SKY130_MODEL_MAP = {
    "nmos_rvt":  "sky130_fd_pr__nfet_01v8",
    "pmos_rvt":  "sky130_fd_pr__pfet_01v8",
    "nmos_lvt":  "sky130_fd_pr__nfet_01v8_lvt",
    "nmos":      "sky130_fd_pr__nfet_01v8",
    "pmos":      "sky130_fd_pr__pfet_01v8",
    "nfet":      "sky130_fd_pr__nfet_01v8",
    "pfet":      "sky130_fd_pr__pfet_01v8",
}
```

---

### `_map_mosfet_model(line: str) -> str`

Internal helper. Maps a single SPICE netlist line's MOSFET model name to the sky130 KLayout-recognized name. Skips comment lines (starting with `*`), directive lines (starting with `.`), and non-M-device lines. Replaces token 6 (the model name) in MOSFET instance lines. Handles shorthands `"n"` and `"p"`. Preserves leading and trailing whitespace.

---

### `prepare_lvs_schematic(schematic_path: str, out_path: str) -> str`

Create a sky130-mapped copy of a schematic for KLayout LVS.

Reads the input schematic, applies `_map_mosfet_model` to every line, and adds `.global vss` if no `.global` directive is present. Writes the result to `out_path`. Returns `str(out_path)`.

**Purpose:** KLayout LVS requires sky130 full model names (e.g., `sky130_fd_pr__nfet_01v8`) rather than short names (e.g., `nmos`, `n`). This function bridges the gap between Spout's generic SPICE netlists and KLayout's PDK-specific LVS scripts.

---

### `run_klayout_lvs(gds_path: str, schematic_path: str, top_cell: str) -> dict`

Run KLayout LVS. Returns `{"match": True}`, `{"match": False, "details": str}`, or `{"error": str}`.

**LVS script discovery:** Tries both `sky130.lylvs` and `sky130.lvs` in `$PDK_ROOT/sky130A/libs.tech/klayout/lvs/`.

**Schematic preparation:** Calls `prepare_lvs_schematic()` to create a sky130-mapped copy in a temporary directory.

**Command constructed:**
```
klayout -b -r <lvs_script>
        -rd input=<gds_abs_path>
        -rd schematic=<prepared_schematic>
        -rd topcell=<top_cell>
        -rd report=<tmpdir>/klayout_lvs_report.lyrdb
```

**Timeout:** 180 seconds.

**Result parsing:** Inspects combined stdout+stderr for:
- `"NETLIST MATCH"` or `"netlists match"` → `{"match": True}`
- `"NETLIST MISMATCH"` or `"netlists don't match"` → `{"match": False, "details": combined}`
- Neither → `{"error": "klayout LVS inconclusive (rc=...): ..."}`

---

### `run_magic_pex(gds_path: str, top_cell: str, work_dir: str) -> dict`

Run Magic ext2spice. Returns `{"num_res": int, "num_cap": int}` or `{"error": str}`.

**Environment dependency:** `$PDK_ROOT` and `magic` in PATH.

**Tech file path:** `$PDK_ROOT/sky130A/libs.tech/magic/sky130A.tech`

**TCL script sent to Magic via stdin:**
```tcl
tech load <tech_file>
gds read <gds_abs_path>
load <top_cell>
select top cell
extract do resistance
extract do capacitance
extract do coupling
extract all
ext2spice hierarchy on
ext2spice format ngspice
ext2spice cthresh 0
ext2spice rthresh 0
ext2spice
puts "EXT2SPICE_DONE"
quit
```

The sentinel `"EXT2SPICE_DONE"` in stdout confirms the extraction completed.

**Magic invocation:** `magic -dnull -noconsole` with `input=tcl` and `cwd=work_abs`. Timeout: 120 seconds.

**Result parsing:**
- Counts lines starting with `C` (capacitors) and `R` (resistors) in `<work_dir>/<top_cell>.spice`
- Also counts `resist ` lines in `<work_dir>/<top_cell>.ext` (double-counts resistors from .ext file)
- Logs `num_res` and `num_cap` at DEBUG level

**Error conditions:**
- `{"error": "magic failed: ..."}` on subprocess timeout or OSError
- `{"error": "ext2spice did not complete ..."}` if sentinel not found
- `{"error": "ext2spice SPICE file not found: ..."}` if output SPICE file missing

---

## `python/tinytapeout.py` — TinyTapeout Integration

### Constants

```python
TT_TILE_WIDTH_UM: float = 160.0    # User area per tile width in microns
TT_TILE_HEIGHT_UM: float = 100.0   # User area per tile height in microns
TT_ANALOG_METAL_LAYER: int = 68    # GDS layer 68, datatype 20 = sky130 M1
TT_WRAPPER_CELL: str = "user_project_wrapper"  # Top-level wrapper cell name
```

### `tinytapeout_template_config(gds_path, num_tiles_x, num_tiles_y) -> TemplateConfig`

Create a `TemplateConfig` for a TinyTapeout submission.

```python
def tinytapeout_template_config(
    gds_path: str,
    num_tiles_x: int = 1,
    num_tiles_y: int = 1,
) -> TemplateConfig:
```

Returns a `TemplateConfig` with:
- `gds_path` = provided path
- `cell_name` = `"user_project_wrapper"` (the standard TinyTapeout wrapper cell)
- `user_area_origin` = `(0.0, 0.0)`

Note: `num_tiles_x` and `num_tiles_y` are currently informational only — the actual bounds are read from the template GDS at runtime via `spout_get_template_bounds`.

### `run_tinytapeout_pipeline(netlist_path, template_gds, output_path, config, num_tiles_x, num_tiles_y) -> PipelineResult`

Convenience wrapper around `run_pipeline` for TinyTapeout submissions.

```python
def run_tinytapeout_pipeline(
    netlist_path: str,
    template_gds: str,
    output_path: str = "submission.gds",
    config: Optional[SpoutConfig] = None,
    num_tiles_x: int = 1,
    num_tiles_y: int = 1,
) -> PipelineResult:
```

When `config` is `None`, uses a default configuration tuned for small TinyTapeout tile areas:
```python
sa = SaConfig(
    initial_temp=500.0,
    cooling_rate=0.995,
    min_temp=0.01,
    max_iterations=30_000,
    perturbation_range=5.0,   # µm — appropriate for 160×100 µm tile
    w_hpwl=1.0,
    w_overlap=100.0,
    w_symmetry=2.0,
)
config = SpoutConfig(pdk="sky130", sa_config=sa)
```

The output GDS hierarchy will be: `top` → `user_project_wrapper` (from template) + `user_analog_circuit` (user circuit cell).

---

## How to Use the Python Layer

### Running the Full Flow

```bash
# CLI
python -m python run my_circuit.spice -o my_circuit.gds --pdk sky130

# With template
python -m python run my_circuit.spice -o output.gds --template-gds tt.gds --template-cell user_project_wrapper

# Python API
from spout.main import run_pipeline
from spout.config import SpoutConfig
result = run_pipeline("my_circuit.spice", SpoutConfig(), "output.gds")
```

### Running Individual Subsystems

```python
import spout
from spout.config import SaConfig

layout = spout.Layout(0, 0)  # magic, sky130
layout.parse_netlist("my_circuit.spice")
layout.extract_constraints()
layout.run_sa_placement(SaConfig().to_ffi_bytes())
layout.run_routing()
layout.export_gdsii_named("output.gds", "my_circuit")
```

### Running Only Signoff Tools

```python
from spout.tools import run_klayout_drc, run_klayout_lvs, run_magic_pex
import tempfile

violations = run_klayout_drc("output.gds", "my_circuit")
lvs = run_klayout_lvs("output.gds", "my_circuit.spice", "my_circuit")
with tempfile.TemporaryDirectory() as d:
    pex = run_magic_pex("output.gds", "my_circuit", d)
```

### Liberty File Generation

```bash
# CLI
python -m python liberty output.gds my_circuit.spice --cell-name my_circuit --all-corners --output-dir lib/

# Python API
import spout
spout.liberty_generate("output.gds", "my.spice", "my_cell", 0, "tt_025C_1v80", "my_cell.lib")
```

### Configuring SA Parameters

```python
from spout.config import SaConfig, SpoutConfig

sa = SaConfig(
    initial_temp=2000.0,     # Higher for complex circuits
    max_iterations=100_000,  # More iterations for better result
    w_symmetry=4.0,          # Higher emphasis on symmetry
    w_matching=3.0,          # Higher emphasis on matching
    w_overlap=200.0,         # Stronger overlap penalty
    perturbation_range=8.0,  # Smaller range for tighter placement
)
config = SpoutConfig(pdk="sky130", sa_config=sa)
```

### Using TinyTapeout

```python
from spout.tinytapeout import run_tinytapeout_pipeline

result = run_tinytapeout_pipeline(
    netlist_path="my_analog.spice",
    template_gds="tt_um_wrapper.gds",
    output_path="submission.gds",
    num_tiles_x=1,
    num_tiles_y=1,
)
print(f"Submission {'ready' if result.success else 'has issues'}: {result.gds_path}")
```
