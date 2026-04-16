# Testing Documentation

Complete documentation of Spout's test infrastructure, covering Zig unit tests, end-to-end tests, and the constraint extractor test suite.

---

## Test Structure and Build Targets

All tests are driven through `build.zig`. The following test steps are available:

| Build step       | Command                    | What it runs                                                    |
| ---------------- | -------------------------- | --------------------------------------------------------------- |
| `test`           | `zig build test`           | Unit tests (src/lib.zig) + end-to-end tests (tests/e2e_tests.zig) |
| `e2e`            | `zig build e2e`            | End-to-end tests only                                           |
| `test-liberty`   | `zig build test-liberty`   | Liberty unit tests (src/liberty/lib.zig)                        |
| `test-template`  | `zig build test-template`  | GDS template import tests (src/import/template.zig)             |
| `test-runner`    | `zig build test-runner`    | Unit tests with pass/fail tick marks (custom test runner)       |
| `size`           | `zig build size`           | Report model struct sizes (size_runner.zig)                     |

The default `zig build test` step depends on both `run_tests` (unit tests from `src/lib.zig`) and `run_e2e` (end-to-end tests), so both run together.

### Test Runner

Spout uses a custom test runner at `tests/test_runner.zig` with `.mode = .simple`. This provides formatted pass/fail output with tick marks rather than the default Zig test output.

### Size Runner

The `tests/size_runner.zig` is a special test runner (mode: `.simple`) that reports the byte sizes of key model structs, set via the `SIZE_SOURCE_FILE=src/lib.zig` environment variable. Useful for tracking ABI-critical struct layout changes.

---

## Unit Tests: `src/constraint/tests.zig`

The constraint extractor tests are the most comprehensive unit test suite in the codebase. They validate the pattern recognition logic that identifies analog circuit structures (differential pairs, current mirrors, cascodes) from netlist topology.

### Test Infrastructure

#### `makeNets(alloc, count, power_nets) -> NetArrays`

Helper function that creates a `NetArrays` with `count` nets and marks the specified net indices as power nets (`is_power = true`). Used to simulate VSS/VDD net identification.

#### `setMosfetPins(pins, base, device, gate_net, drain_net, source_net, body_net)`

Helper function that populates four MOSFET pin-edge records (gate, drain, source, body) starting at index `base` in a `PinEdgeArrays`. Assigns:
- `pins.device[base+0..3] = DeviceIdx.fromInt(device)` (same device for all four)
- `pins.net[base+0] = NetIdx.fromInt(gate_net)`
- `pins.net[base+1] = NetIdx.fromInt(drain_net)`
- `pins.net[base+2] = NetIdx.fromInt(source_net)`
- `pins.net[base+3] = NetIdx.fromInt(body_net)`
- `pins.terminal[base+0] = .gate`
- `pins.terminal[base+1] = .drain`
- `pins.terminal[base+2] = .source`
- `pins.terminal[base+3] = .body`

#### `countConstraintsOfType(result, ctype) -> u32`

Counts constraints of a specific type in the result `ConstraintArrays`. Used in test assertions.

---

### Test: Differential Pair Produces 1 Symmetry Constraint

```
test "differential pair produces 1 symmetry constraint"
```

**Circuit topology:**
```
D0 (NMOS): gate=N0(INP), drain=N2(diff_a), source=N4(tail), body=N5(VSS)
D1 (NMOS): gate=N1(INN), drain=N3(diff_b), source=N4(tail), body=N5(VSS)
```

**Conditions that trigger symmetry detection:**
- Same device type (both NMOS)
- Same W/L (both 2.0µm / 0.13µm)
- Shared source net (N4 = tail)
- Different gate nets (N0 ≠ N1)

**Expected result:** Exactly 1 constraint of type `.symmetry`.

**Verified properties:**
- `result.device_a[0] == DeviceIdx.fromInt(0)` (D0 is device_a)
- `result.device_b[0] == DeviceIdx.fromInt(1)` (D1 is device_b)
- `result.weight[0] == 1.0` (symmetry weight)
- `result.types[0] == .symmetry`

---

### Test: Current Mirror Produces 1 Matching Constraint

```
test "current mirror produces 1 matching constraint"
```

**Circuit topology:**
```
D0 (NMOS): gate=N0(bias), drain=N0(bias), source=N2(VSS), body=N3(VSS)  [diode-connected]
D1 (NMOS): gate=N0(bias), drain=N1(out),  source=N2(VSS), body=N3(VSS)
```

**Conditions that trigger matching detection:**
- Same device type (both NMOS)
- Same W/L (both 4.0µm / 0.5µm)
- Shared gate net (N0)
- D0 is diode-connected (gate net == drain net == N0)

**Expected result:** Exactly 1 constraint of type `.matching`.

**Verified properties:**
- Matching constraint exists
- `result.weight[i] == 0.8` (matching weight for current mirrors)

---

### Test: Cascode Produces 1 Proximity Constraint

```
test "cascode produces 1 proximity constraint"
```

**Circuit topology:**
```
D0 (NMOS): gate=N0, drain=N1(mid), source=N2(VSS), body=N3(VSS)
D1 (NMOS): gate=N4, drain=N5(out), source=N1(mid), body=N3(VSS)
```

**Condition that triggers proximity detection:**
- `drain(D0) == N1 == source(D1)` — drain-to-source chain

**Expected result:** Exactly 1 constraint of type `.proximity`.

**Verified properties:**
- `result.device_a[i] == DeviceIdx.fromInt(0)` (D0 is the bottom device, whose drain feeds)
- `result.device_b[i] == DeviceIdx.fromInt(1)` (D1 is the cascode device, whose source is fed)
- `result.weight[i] == 0.5` (proximity weight for cascodes)

---

### Test: Unrelated Devices Produce 0 Constraints

```
test "unrelated devices produce 0 constraints"
```

**Circuit topology:**
```
D0 (NMOS): gate=N0, drain=N1, source=N2, body=N3  [all unique nets]
D1 (NMOS): gate=N4, drain=N5, source=N6, body=N7  [all unique nets]
```

No shared nets, no diode connection, no drain-to-source chain.

**Expected result:** `result.len == 0` (no constraints of any type).

---

### Test: Different Device Types Block Diff-Pair Detection

```
test "diff pair pattern with different device types produces 0 symmetry"
```

**Circuit topology:** Same connectivity as the differential pair test, but D0 is NMOS and D1 is PMOS.

**Expected result:** 0 symmetry constraints (type mismatch blocks the pattern).

---

### Test: Different W Blocks Diff-Pair Detection

```
test "diff pair pattern with different W blocks symmetry"
```

**Circuit topology:** Differential pair connectivity, both NMOS, but D0 has W=2µm and D1 has W=4µm.

**Expected result:** 0 symmetry constraints (W mismatch blocks the pattern — cannot form a symmetric pair with unequal sizing).

---

### Test: Shared Gate Without Diode Connection Does Not Trigger Matching

```
test "shared gate without diode connection produces 0 matching"
```

**Circuit topology:**
```
D0 (NMOS): gate=N0, drain=N1, source=N3, body=N4
D1 (NMOS): gate=N0, drain=N2, source=N3, body=N4
```

Both share gate (N0) and source (N3), but **neither is diode-connected** (no device has gate==drain). This is a valid topology (could be a differential pair with a common gate bias) but not a current mirror pattern.

**Expected result:** 0 matching constraints (diode connection is required for current mirror detection).

---

### Test: Cascode Detected in Reverse Direction

```
test "cascode detected in reverse direction"
```

**Circuit topology:**
```
D0 (NMOS): gate=N0, drain=N3, source=N1, body=N4  [source=N1]
D1 (NMOS): gate=N5, drain=N1, source=N2, body=N4  [drain=N1]
```

`drain(D1) == N1 == source(D0)` — the cascode relationship exists with D1 as the "bottom" device and D0 as the "top" device (reverse of the main test).

**Expected result:** 1 proximity constraint.

**Verified properties:**
- `result.device_a[i] == DeviceIdx.fromInt(1)` (D1 is the bottom device, whose drain feeds)
- `result.device_b[i] == DeviceIdx.fromInt(0)` (D0 is the cascode device)

---

### Test: Empty Circuit Produces 0 Constraints

```
test "empty circuit produces 0 constraints"
```

An empty circuit (0 devices, 0 pins, 0 nets, 0 adjacencies).

**Expected result:** `result.len == 0`.

---

### Test: Single Device Produces 0 Constraints

```
test "single device produces 0 constraints"
```

A circuit with exactly 1 NMOS transistor (4 pins).

**Expected result:** `result.len == 0` (constraints require at least 2 devices).

---

### Test: Five-Transistor OTA (Integration Test)

```
test "five-transistor OTA: diff pair + current mirror + cascode"
```

**Circuit topology:**
```
M0 (NMOS): gate=INP(N0), drain=diff_a(N2), source=tail(N4), body=VSS(N5)  — diff pair leg
M1 (NMOS): gate=INN(N1), drain=diff_b(N3), source=tail(N4), body=VSS(N5)  — diff pair leg
M2 (PMOS): gate=VDD(N6), drain=diff_a(N2), source=VDD(N6), body=VDD(N6)   — load
M3 (PMOS): gate=VDD(N6), drain=diff_b(N3), source=VDD(N6), body=VDD(N6)   — load
M4 (NMOS): gate=bias(N7), drain=tail(N4),  source=VSS(N5),  body=VSS(N5)   — tail bias
```

This is the canonical 5-transistor OTA topology. It contains:
- A differential pair (M0, M1): shared source=N4(tail), different gates
- A PMOS current mirror load (M2, M3): shared gate=N6(VDD), M2 diode-connected (gate=source=VDD is **not** gate=drain, so this might NOT trigger matching — the exact pattern detection depends on the extractor implementation)
- A cascode-like relationship between M4 (tail) and M0/M1 (drain(M4)=source(M0)=source(M1)=N4)

**Expected results:**
- At least 1 symmetry constraint (M0–M1 differential pair)
- May produce matching constraints for M2–M3 depending on diode detection
- May produce proximity constraints for M4–M0 and M4–M1

**Purpose:** This test validates that the constraint extractor correctly processes multi-device circuits with overlapping topological patterns without producing spurious or incorrect constraints.

---

## Test Coverage Areas

### Constraint Extractor Coverage

| Pattern                     | Test(s)                              | Verified                          |
| --------------------------- | ------------------------------------ | --------------------------------- |
| Differential pair           | diff pair test, 5T OTA               | Symmetry constraint, weight=1.0   |
| Current mirror              | current mirror test                  | Matching constraint, weight=0.8   |
| Cascode                     | cascode test, reverse cascode        | Proximity constraint, weight=0.5  |
| Type mismatch rejection     | different types test                 | No symmetry for mixed NMOS/PMOS   |
| Size mismatch rejection     | different W test                     | No symmetry for unequal sizing    |
| Diode requirement           | shared gate no diode test            | No matching without diode-connect |
| Direction independence      | reverse cascode test                 | Correct device_a/device_b order   |
| Degenerate inputs           | empty circuit, single device         | No constraints, no crash          |
| Complex multi-pattern       | 5T OTA test                          | Correct handling of overlaps      |

### What Constraint Extractor Tests Do NOT Cover

- Constraint extraction from actual parsed SPICE files (integration test level)
- PMOS differential pairs
- Cascode current mirrors
- Floating gates / antenna violations
- Multi-stage opamps with more than 5 devices
- BJT, diode, resistor, capacitor constraint patterns

---

## Running Tests

### Zig Unit Tests

```bash
# All tests (unit + e2e)
zig build test

# Unit tests only
zig build test  # (e2e is included in the 'test' step)

# With custom pass/fail display
zig build test-runner

# Liberty subsystem tests
zig build test-liberty

# GDS template import tests
zig build test-template

# Struct size report
zig build size
```

### Test Output

Default Zig test output shows pass/fail counts. The custom test runner (`tests/test_runner.zig`) formats each test with a `✓` or `✗` prefix and the test name.

### Testing the Python Layer

From the project root (after `zig build pyext`):

```bash
# Run all Python tests via pytest
pytest tests/

# Run specific test file
pytest tests/test_python_refactor.py

# Run with verbose output
pytest -v tests/
```

Note: Most Python test files are currently marked as deleted in git status (prefixed with `D`). The active Python test infrastructure is being rebuilt.

---

## Test Data and Fixtures

### Benchmark SPICE Files

Located at `fixtures/benchmark/*.spice` (directory structure — the benchmark directory may need to be created). Each file is a SPICE netlist with a `.subckt` definition representing one analog building block:

| Expected circuit name | Description                            |
| --------------------- | -------------------------------------- |
| `current_mirror`      | Simple NMOS current mirror             |
| `diff_pair`           | NMOS differential pair with tail       |
| `cascode`             | Cascode amplifier stack                |
| `diff_amp`            | Differential amplifier (5T OTA)        |

### Inline Test Data (constraint tests)

All data is constructed inline in the test functions:
- `DeviceArrays` — device types and parameters (W, L, fingers, mult, value)
- `PinEdgeArrays` — pin-device-net-terminal connections
- `NetArrays` — net fanout and power flags
- `FlatAdjList` — built from pin arrays via `buildFromSlices()`
- `ConstraintArrays` — result of `extractConstraints()`

---

## Test Design Patterns

### Resource Management Pattern

Every test follows the Zig defer/deinit pattern:

```zig
var devices = try DeviceArrays.init(alloc, 2);
defer devices.deinit();
// ...
var result = try extract.extractConstraints(alloc, &devices, &nets, &pins, &adj);
defer result.deinit();
```

Using `std.testing.allocator` enables the Zig test framework to detect memory leaks — if `deinit()` is missing, the allocator reports a leak and the test fails.

### Constraint Search Pattern

Because constraint ordering is not guaranteed (and may include multiple constraint types from pattern overlaps), tests search by type rather than assuming index positions:

```zig
// For matching constraint verification:
var found = false;
for (0..result.len) |i| {
    if (result.types[i] == .matching) {
        try std.testing.expectEqual(@as(f32, 0.8), result.weight[i]);
        found = true;
        break;
    }
}
try std.testing.expect(found);
```

### Adjacency List Construction

In real code, the adjacency list is built from parsed SPICE data via `FlatAdjList.build()`. In tests, `FlatAdjList.buildFromSlices()` accepts raw arrays directly, bypassing the parser:

```zig
var adj = try FlatAdjList.buildFromSlices(alloc, n_devices, n_nets, n_pins, pins.device, pins.net);
defer adj.deinit();
```

---

## Integration with the Full Pipeline

The constraint tests are unit tests operating on manually constructed data. The full integration path is:

1. `spout_parse_netlist()` → populates DeviceArrays, NetArrays, PinEdgeArrays, builds FlatAdjList
2. `spout_extract_constraints()` → calls `constraint_extract.extractConstraints()`
3. SA placer reads constraint arrays via `ctx.constraints.*` fields
4. Constraints influence cost function via `w_symmetry` and `w_matching` weights

The constraint extractor tests verify step 2 in isolation, ensuring the pattern recognition logic is correct before the placer uses it.
