# PEX Equivalence: Spout In-Engine PEX == MAGIC PEX

> **Token saving**: Start every session with `/caveman` to use compressed output and save tokens.

## Goal

Make Spout's in-engine PEX produce parasitic element counts and values that **match MAGIC's ext2spice extraction within 5%** for ALL benchmark circuits. "Done" means `scripts/compare_pex.py --all` exits 0 (all circuits show R and C ratio within 0.95x–1.05x).

## Architecture

- **Spout PEX engine**: `src/characterize/pex.zig` — parasitic R/C extraction from routed layout
- **PEX types**: `src/characterize/types.zig` — PexConfig, layer coefficients
- **Comparison oracle**: `scripts/compare_pex.py` — runs Spout pipeline + MAGIC ext2spice, compares element counts and total values
- **MAGIC reference**: `ext2spice` with `cthresh 0` and `rthresh 0` (extracts ALL parasitics)

## Iteration Protocol

Every iteration MUST follow this exact cycle:

### 1. Read State
```bash
cat prompts/progress_pex.txt 2>/dev/null || echo "First iteration"
```

### 2. Run Comparison (ground truth)
```bash
nix develop --command bash -c "zig build -Doptimize=ReleaseFast && cp zig-out/lib/libspout.so python/libspout.so && python scripts/compare_pex.py --all --verbose"
```
Record: R count ratio, C count ratio, total R ratio, total C ratio per circuit.

### 3. Research
- Read `src/characterize/pex.zig` — understand current extraction model
- From the comparison output, identify which metric is furthest off (R count? C value? etc.)
- Compare per-net breakdown (verbose output) to identify WHERE the discrepancy is
- Check: Are there too many/few wire segments being extracted? Wrong layer coefficients? Missing via contributions? Substrate cap model wrong?

### 4. Implement ONE Fix
- Fix the specific PEX issue causing the largest discrepancy
- Primary file: `src/characterize/pex.zig`
- May also need: `src/characterize/types.zig` (PexConfig/layer coefficients), `src/pdk/` files

### 5. Test
```bash
nix develop --command bash -c "zig build -Doptimize=ReleaseFast && cp zig-out/lib/libspout.so python/libspout.so && python scripts/compare_pex.py --all --verbose"
```
Did ratios move closer to 1.0x? Did any previously-close circuits regress?

### 6. Commit + Record Progress
```bash
git add src/characterize/ src/pdk/
git commit -m "pex: <what was fixed> — C ratio now X (was Y) for <circuit>"
```
Append to `prompts/progress_pex.txt`:
- Which coefficient/model was changed and why
- Before/after ratios per circuit
- What the next largest discrepancy is

## Known Context (from prior sessions)

- **LI coefficients**: corrected from 0.125 to 12.8 Ohm/sq (102x fix)
- **Via resistance**: added (mcon=9.3, v1=4.5, v2=3.41, via3=3.41, via4=0.38 Ohm)
- **PexConfig indexing**: index 0 = LI, index 1 = M1 (was swapped)
- **Coupling model**: replaced O(n^2) all-pairs with nearest-neighbor only
- **Coupling distance**: reduced from 8.0um to ~0.2um per layer (MAGIC sidehalo=0.08um)
- **Root cause of C overcount**: NOT coupling formula — disabling coupling still shows 11.7x over for five_transistor_ota
- **Actual root cause**: substrate cap — Spout's RouteArrays have more total wire area/length than MAGIC sees (many short LI/stub segments that MAGIC merges into device tiles)
- **Simple circuits** (current_mirror, diff_pair): C within 75-84% of MAGIC — close
- **Complex circuits** (folded_cascode, sar_adc): C is 2.7-3.6x MAGIC; five_transistor_ota is 12x

## Key Files

| File | Purpose |
|------|---------|
| `src/characterize/pex.zig` | PEX extraction engine — R/C computation |
| `src/characterize/types.zig` | PexConfig, layer sheet resistance, via resistance |
| `src/pdk/` | PDK layer definitions and coefficients |
| `scripts/compare_pex.py` | Comparison oracle (DO NOT MODIFY to fake results) |
| `scripts/compare_pex_values.py` | Detailed per-value comparison (supplementary) |
| `prompts/progress_pex.txt` | Persistent progress across iterations |

## Exit Condition

`python scripts/compare_pex.py --all` exits with code 0 — meaning ALL circuits show R and C ratios within 0.95x–1.05x of MAGIC.

## Important Constraints

- All commands must run under `nix develop --command`
- After `zig build`, always `cp zig-out/lib/libspout.so python/libspout.so`
- Do NOT modify comparison scripts to fake results
- Do NOT change MAGIC's extraction parameters (cthresh/rthresh) to make comparison easier
- The fix must be in Spout's extraction model, not in how we compare
- One focused fix per iteration — tackle the largest discrepancy first
