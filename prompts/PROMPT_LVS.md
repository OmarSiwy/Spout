# LVS Equivalence: Spout ext2spice → NETGEN MATCH for all circuits

> **Token saving**: Start every session with `/caveman` to use compressed output and save tokens.

## Goal

Make Spout's in-engine ext2spice produce SPICE netlists that NETGEN accepts as matching the schematic for **ALL** benchmark circuits. "Done" means `scripts/compare_lvs.py --all` exits 0 (all circuits show Spout=MATCH).

Note: LVS connectivity checking already works. The focus is **ext2spice** — the function that extracts a SPICE netlist from the routed layout. This netlist must be valid enough for NETGEN to verify it matches the original schematic.

## Architecture

- **Spout ext2spice**: `src/characterize/ext2spice.zig` — generates SPICE from routed layout
- **Netlist parser**: `src/netlist/tokenizer.zig`, `src/netlist/types.zig` — parses input SPICE
- **FFI bridge**: `src/lib.zig` exports `spout_ext2spice`, `python/ffi.py` wraps it
- **Comparison oracle**: `scripts/compare_lvs.py` — runs Spout ext2spice + MAGIC ext2spice, feeds both through NETGEN
- **NETGEN reference**: batch LVS comparing layout SPICE vs schematic SPICE

## Iteration Protocol

Every iteration MUST follow this exact cycle:

### 1. Read State
```bash
cat prompts/progress_lvs.txt 2>/dev/null || echo "First iteration"
```

### 2. Run Comparison (ground truth)
```bash
nix develop .#test --command bash -c "zig build -Doptimize=ReleaseFast && cp zig-out/lib/libspout.so python/libspout.so && python scripts/compare_lvs.py --all"
```
Record: how many circuits show Spout=MATCH vs MISMATCH? Which ones fail?

### 3. Research
- For the first MISMATCH circuit, run with `--verbose` to see the actual SPICE output
- Compare Spout's ext2spice output vs what NETGEN expects
- Check for: missing devices (MOSFETs, R, C), wrong port ordering, missing subcircuit hierarchy, wrong model names, wrong W/L values
- Read `src/characterize/ext2spice.zig` to understand what's currently generated

### 4. Implement ONE Fix
- Fix the specific ext2spice issue causing the MISMATCH
- Primary files: `src/characterize/ext2spice.zig`, `src/netlist/tokenizer.zig`, `src/netlist/types.zig`
- If FFI changes are needed: `src/lib.zig`, `python/ffi.py`

### 5. Test
```bash
nix develop .#test --command bash -c "zig build -Doptimize=ReleaseFast && cp zig-out/lib/libspout.so python/libspout.so && python scripts/compare_lvs.py --all"
```
Did the MATCH count go up? Did any previously-passing circuits regress?

### 6. Commit + Record Progress
```bash
git add src/ python/
git commit -m "ext2spice: <what was fixed> — now N/39 MATCH (was M/39)"
```
Append to `prompts/progress_lvs.txt`:
- Which circuit was fixed and how
- Current MATCH count
- What the next failing circuit's issue is

## Known Context (from prior sessions)

- **22/39 MATCH** — all flat MOSFET-only circuits pass
- **17 MISMATCH** circuits all have hierarchical subcircuit instances (X devices) or passive components (R, C)
- **MAGIC ext2spice: 0/39 MATCH** — MAGIC can't extract from auto-placed/routed GDS (so don't rely on MAGIC path)
- **Fixed bugs**: dangling pointer in subcircuit name/ports (finalize/dupe), missing ctypes signature for spout_ext2spice, model_name memory leak
- **Important**: after `zig build`, must `cp zig-out/lib/libspout.so python/libspout.so`
- **Important**: LVS comparison uses `nix develop .#test` (not default devshell) for netgen binary

## Key Files

| File | Purpose |
|------|---------|
| `src/characterize/ext2spice.zig` | SPICE netlist generation from layout |
| `src/characterize/lvs.zig` | LVS connectivity checking |
| `src/netlist/tokenizer.zig` | SPICE netlist parser |
| `src/netlist/types.zig` | Netlist data structures (Subcircuit, model_name, etc.) |
| `src/lib.zig` | FFI exports (spout_ext2spice) |
| `python/ffi.py` | Python FFI wrapper |
| `scripts/compare_lvs.py` | Comparison oracle (DO NOT MODIFY to fake results) |
| `prompts/progress_lvs.txt` | Persistent progress across iterations |

## Exit Condition

`python scripts/compare_lvs.py --all` exits with code 0 — meaning ALL circuits show Spout=MATCH via NETGEN.

## Important Constraints

- Use `nix develop .#test --command` (the test devshell has netgen/magic)
- After `zig build`, always `cp zig-out/lib/libspout.so python/libspout.so`
- Do NOT modify comparison scripts to fake results
- Do NOT skip circuits — ALL 39 must pass
- Focus on ext2spice output correctness, not LVS engine changes
- One focused fix per iteration
