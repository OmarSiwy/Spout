# Build System

> **Source files:** `build.zig`, `build.zig.zon`

---

## 1. Project Identity

```zon
{
    .fingerprint = 0x775d9e9f81d408e6,
    .name = .spout2,
    .version = "0.1.0",
    .paths = .{ "src", "build.zig", "build.zig.zon" },
}
```

The package is named `spout2` internally (the Zig package name). The shared library is named `spout` (producing `libspout.so`). Python consumers import it as `spout`.

---

## 2. Build Targets

Running `zig build` with no arguments produces the default install step, which includes:

| Artifact | Output Location | Description |
|---|---|---|
| `libspout.so` | `zig-out/lib/libspout.so` AND `python/libspout.so` | Shared library — C-ABI surface for Python ctypes |
| (optional) `spout.so` | `python/spout.so` | Native CPython extension (requires `zig build pyext`) |

### 2.1 `zig build` (default)

Builds `libspout.so` and installs it to both `zig-out/lib/` and `python/`.

```zig
const lib = b.addLibrary(.{
    .name = "spout",
    .root_module = spout_mod,
    .linkage = .dynamic,
});
b.installArtifact(lib);

// Also copy to python/ for ctypes import
const install_to_python = b.addInstallFileWithDir(
    lib.getEmittedBin(),
    .{ .custom = "../python" },
    "libspout.so",
);
b.getInstallStep().dependOn(&install_to_python.step);
```

### 2.2 `zig build pyext` — Native Python Extension

Produces `python/spout.so`, a CPython extension module built using the `PyOZ` framework. This replaces the ctypes-based `libspout.so` import with a proper Python extension that can:
- Accept Python objects directly (e.g., `pyoz.Bytes` for the SA config)
- Return Python objects
- Raise Python exceptions on errors

```zig
const pyext = b.addSharedLibrary(.{
    .name = "spout",
    .root_module = pyext_mod,
    .linkage = .dynamic,
});
pyext.linkLibC();  // Required for CPython API
```

The extension is defined in `src/python_ext.zig` and wraps every public function from `src/lib.zig`.

### 2.3 `zig build test` — Unit Tests

Runs all unit tests embedded in `src/lib.zig` (which transitively pulls in all module tests) plus the end-to-end tests:

```zig
const tests = b.addTest(.{
    .root_module = b.createModule(.{
        .root_source_file = b.path("src/lib.zig"),
        ...
    }),
});
test_step.dependOn(&run_tests.step);
test_step.dependOn(&run_e2e.step);  // e2e tests also run on "zig build test"
```

Every `.zig` file with `test "..." { }` blocks is included when the test runner traverses the import graph from `src/lib.zig`.

### 2.4 `zig build e2e` — End-to-End Tests Only

```zig
const e2e_tests = b.addTest(.{
    .root_module = e2e_mod,  // tests/e2e_tests.zig
});
```

End-to-end tests in `tests/e2e_tests.zig` import the `spout` module and run full pipeline scenarios (parse → place → route → export).

### 2.5 `zig build test-liberty` — Liberty Unit Tests

```zig
const liberty_tests = b.addTest(.{
    .root_module = b.createModule(.{
        .root_source_file = b.path("src/liberty/lib.zig"),
        ...
    }),
});
```

Runs only the Liberty-subsystem tests (PVT corner generation, SPICE testbench, Liberty file format). Faster than the full test suite when working on Liberty.

### 2.6 `zig build test-template` — GDS Template Import Tests

```zig
const template_tests = b.addTest(.{
    .root_module = b.createModule(.{
        .root_source_file = b.path("src/import/template.zig"),
        ...
    }),
});
```

Tests the GDS template import subsystem (reading TinyTapeout wrappers, etc.).

### 2.7 `zig build test-runner` — Pass/Fail Display Runner

```zig
const test_runner_tests = b.addTest(.{
    .name = "test-runner",
    .root_module = b.createModule(.{
        .root_source_file = b.path("src/lib.zig"),
        ...
    }),
    .test_runner = .{
        .path = b.path("tests/test_runner.zig"),
        .mode = .simple,
    },
});
```

Uses a custom test runner (`tests/test_runner.zig`) that prints tick marks (✓/✗) for each test, making it easier to see which specific tests pass or fail. The standard Zig test runner only reports totals.

### 2.8 `zig build size` — Struct Size Reporter

```zig
const size_tests = b.addTest(.{
    .name = "size-runner",
    ...
    .test_runner = .{
        .path = b.path("tests/size_runner.zig"),
        .mode = .simple,
    },
});
run_size.setEnvironmentVariable("SIZE_SOURCE_FILE", "src/lib.zig");
```

Runs `tests/size_runner.zig` which reports the `@sizeOf` for key structs. Useful for tracking memory layout changes and confirming struct sizes match C-ABI expectations.

---

## 3. Module Architecture

```
build.zig
├── spout_mod (src/lib.zig)
│   ├── core/types.zig
│   ├── core/device_arrays.zig
│   ├── core/route_arrays.zig
│   ├── core/net_arrays.zig
│   ├── core/pin_edge_arrays.zig
│   ├── core/constraint_arrays.zig
│   ├── core/adjacency.zig
│   ├── core/layout_if.zig
│   ├── pdk/pdk.zig
│   ├── netlist/lib.zig
│   ├── constraint/extract.zig
│   ├── constraint/patterns.zig
│   ├── placer/sa.zig
│   ├── placer/cost.zig
│   ├── placer/rudy.zig
│   ├── router/lib.zig
│   ├── router/inline_drc.zig
│   ├── router/maze.zig
│   ├── router/detailed.zig
│   ├── router/steiner.zig
│   ├── router/lp_sizing.zig
│   ├── export/gdsii.zig
│   ├── import/gdsii.zig
│   ├── import/template.zig
│   ├── macro/lib.zig
│   ├── characterize/lib.zig
│   └── liberty/lib.zig
│
├── pyext_mod (src/python_ext.zig)
│   ├── imports: PyOZ (from PyOZ dependency)
│   └── imports: spout (= spout_mod above)
│
└── e2e_mod (tests/e2e_tests.zig)
    └── imports: spout (= spout_mod above)
```

All modules compile from the same `src/lib.zig` entry point. The Zig compiler resolves the import graph transitively. Tests are embedded in each source file and discovered automatically.

---

## 4. External Dependencies

### 4.1 PyOZ

```zon
.PyOZ = .{
    .url = "https://github.com/pyozig/PyOZ/releases/download/v0.12.2/PyOZ-0.12.2.tar.gz",
    .hash = "sha256:dc488941dd07c5d41ff7fc8f450b51ea77a01158e4299ea2ce7d8035a3d274d5",
},
```

**Purpose:** PyOZ is a Zig framework for writing native CPython extension modules. It provides:
- `pyoz.Bytes` — Python bytes object access from Zig
- Automatic Python exception conversion from Zig errors
- Python type registration for Zig structs (the `Layout` class)

**Version:** v0.12.2

**Only used for:** The `pyext` build target (`src/python_ext.zig`). The main `libspout.so` (ctypes path) does not use PyOZ.

**No other Zig package dependencies.** All other functionality (routing, placement, GDSII I/O, DRC, PEX) is implemented directly in Zig with no external packages.

---

## 5. Python FFI — Two Modes

### 5.1 ctypes Mode (`libspout.so`)

```python
# python/__init__.py imports spout (the native extension module)
import ctypes
lib = ctypes.CDLL("libspout.so")
lib.spout_init_layout.restype = ctypes.c_void_p
# ...
```

`python/config.py` defines `_SaConfigC` — a `ctypes.Structure` mirroring the C-ABI layout of `SaConfig` from `src/placer/types.zig`:

```python
class _SaConfigC(ctypes.Structure):
    _fields_ = [
        ("initialTemp", ctypes.c_float),
        ("coolingRate", ctypes.c_float),
        # ... 24 fields total
    ]
```

`SaConfig.to_ffi_bytes()` serializes the Python dataclass into this ctypes struct and returns `bytes`, which can be passed directly to `spout_run_sa_placement`.

### 5.2 Native Extension Mode (`spout.so`)

```python
import spout  # imports python/spout.so — native CPython extension
layout = spout.Layout(backend_id, pdk_id)
layout.parse_netlist("/path/to/circuit.spice")
```

`src/python_ext.zig` defines the `Layout` class using PyOZ:

```zig
const Layout = struct {
    _handle: *anyopaque,

    pub fn __new__(backend: u8, pdk_id: u8) !Layout { ... }
    pub fn __del__(self: *Layout) void { lib.spout_destroy(self._handle); }
    pub fn parse_netlist(self: *Layout, path: []const u8) !void { ... }
    pub fn run_sa_placement(self: *Layout, config: pyoz.Bytes) !void { ... }
    // ...
};
```

The `pyext` mode is cleaner (no ctypes boilerplate) and exposes more methods, but requires `zig build pyext` before use.

---

## 6. Build Configuration

### 6.1 Target and Optimize Options

`build.zig` uses Zig's standard options:

```zig
const target = b.standardTargetOptions(.{});
const optimize = b.standardOptimizeOption(.{});
```

**Debug mode (`zig build`):** No optimization (`optimize = .Debug`). Safety checks enabled (integer overflow, array bounds, etc.).

**Release mode (`zig build -Doptimize=ReleaseFast`):** Full optimization, safety checks disabled. Typical 5–10× speedup for the SA placer.

**ReleaseSafe (`zig build -Doptimize=ReleaseSafe`):** Full optimization with safety checks. Recommended for testing release performance while catching bugs.

### 6.2 Cross-compilation

Standard Zig cross-compilation: `zig build -Dtarget=x86_64-linux-gnu`. No target-specific code in `src/` (no inline assembly, no OS-specific APIs except through `std.process` for environment variable reading).

---

## 7. Python Package Structure

```
python/
├── __init__.py          # Re-exports SpoutConfig, run_pipeline, etc.
├── config.py            # SpoutConfig, SaConfig, MacroDefinition
├── main.py              # run_pipeline(), CLI entry point
├── tools.py             # run_klayout_drc(), run_klayout_lvs(), run_magic_pex()
├── libspout.so          # (generated by zig build) ctypes shared library
└── spout.so             # (generated by zig build pyext) native extension
```

The Python package is installed as `spout` (the directory name, or by configuring `sys.path` to include `python/`). `python/__init__.py` re-exports the public API:
- `SpoutConfig`, `SaConfig` (from `config.py`)
- `run_pipeline`, `PipelineResult`, `TemplateConfig` (from `main.py`)
- `LibertyResult`, `LibertyAllCornersResult` (from `main.py`)

The package does NOT include `tools.py` exports — the signoff tools are used internally by `main.py` but are not part of the public API.

---

## 8. Test Discovery and Running

### Zig tests

```bash
zig build test              # All unit + e2e tests
zig build e2e               # End-to-end tests only
zig build test-liberty      # Liberty subsystem tests
zig build test-template     # GDS template tests
zig build test-runner       # Visual pass/fail output
zig build size              # Struct size report
```

### Python tests (pytest)

```bash
pytest tests/               # All Python integration tests
python scripts/benchmark.py  # Performance benchmark
```

The benchmark script (`scripts/benchmark.py`) runs the full pipeline on every `.spice` file in `fixtures/benchmark/` (excluding LVS/PEX artifacts) and produces a timing table by phase.

---

## 9. Key Build Invariants

1. **`zig build` always installs `libspout.so` to `python/`** — the Python package can always find it after a build.

2. **Unit tests are in source files** — every `.zig` file may have inline `test` blocks. `zig build test` discovers all of them via the import graph from `src/lib.zig`.

3. **No circular imports** — Zig's module system prevents circular dependencies. The `lib.zig` entry point is a hub; each subsystem module imports only from `core/`.

4. **C linkage is in `lib.zig`** — all `export fn spout_*` declarations live in `src/lib.zig`. Subsystem modules do not export C symbols.

5. **`PyOZ` is optional** — the default build (`zig build`) does not require PyOZ. Only `zig build pyext` does. This allows building without a Python installation.
