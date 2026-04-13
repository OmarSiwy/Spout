# DRC Equivalence: Spout In-Engine DRC == MAGIC DRC

> **Token saving**: Start every session with `/caveman` to use compressed output and save tokens.

## Goal

Make Spout's in-engine DRC produce **identical violation counts** to MAGIC's DRC for ALL benchmark circuits. "Done" means `scripts/compare_drc.py --all` exits 0 (delta=0 for every circuit).

## Architecture

- **Spout DRC engine**: `src/characterize/drc.zig` — geometric rule checker
- **DRC rules**: loaded from PDK config (sky130.json in `src/pdk/`)
- **Comparison oracle**: `scripts/compare_drc.py` — runs both Spout and MAGIC on same GDS, compares per-rule and total counts
- **MAGIC reference**: uses `drc listall count` (deduped unique tiles) and `drc listall why` (per-rule rects)

## Iteration Protocol

Every iteration MUST follow this exact cycle:

### 1. Read State
```bash
cat prompts/progress_drc.txt 2>/dev/null || echo "First iteration"
```

### 2. Run Comparison (ground truth)
```bash
nix develop --command bash -c "zig build -Doptimize=ReleaseFast && cp zig-out/lib/libspout.so python/libspout.so && python scripts/compare_drc.py --all"
```
Record the output. This is your current delta per circuit.

### 3. Research
- Read `src/characterize/drc.zig` — understand current rule implementations
- Read the MAGIC detailed rules output from step 2 — identify which MAGIC rules have no Spout equivalent
- Compare rule-by-rule: which rules does Spout undercount? Overcount?
- Pick the **single highest-impact gap** (largest delta contributor)

### 4. Implement ONE Fix
- Make a focused change to close the gap identified in step 3
- Only touch `src/characterize/drc.zig` and/or `src/pdk/` files
- Do NOT change the comparison script to make numbers look better

### 5. Test
```bash
nix develop --command bash -c "zig build -Doptimize=ReleaseFast && cp zig-out/lib/libspout.so python/libspout.so && python scripts/compare_drc.py --all"
```
Compare new output vs step 2. Did the delta improve?

### 6. Commit + Record Progress
```bash
git add src/characterize/drc.zig src/pdk/
git commit -m "drc: <what was fixed> — delta reduced from X to Y"
```
Append findings to `prompts/progress_drc.txt`:
- What rule was added/fixed
- Before/after delta per circuit
- What the next highest-impact gap is

## Known Context (from prior sessions)

- **MAGIC deduplication**: `drc listall count` returns UNIQUE error tiles. `drc listall why` lists tiles under EVERY rule. The 2.48x ratio means per-rule rect counts can't estimate per-rule tile counts.
- **Union-find area merge**: Already implemented. MAGIC merges all connected same-layer paint before checking min_area.
- **Device-level rules gap**: MAGIC checks ~45 rules including device-aware rules (varactor, transistor geometry, well spacing). Spout checks ~25 geometric rules. These device rules require contextual knowledge (NMOS vs PMOS, poly-contact vs diff-contact).
- **Grid snapping**: Only 3 tiles difference — NOT the main issue.
- **Last known deltas**: current_mirror=-44, diff_pair=-49, five_transistor_ota=-126 (Spout undercounts)
- **High-impact gaps**: (1) tap-to-nwell cross-rule spacing (diff/tap.11), (2) nwell-over-tap enclosure (diff/tap.10), (3) false SHORT violations in five_transistor_ota (26 with 0 from MAGIC)

## Key Files

| File | Purpose |
|------|---------|
| `src/characterize/drc.zig` | DRC engine — rule checking logic |
| `src/characterize/types.zig` | DRC types and data structures |
| `src/pdk/` | PDK config including sky130.json rule definitions |
| `scripts/compare_drc.py` | Comparison oracle (DO NOT MODIFY to fake results) |
| `prompts/progress_drc.txt` | Persistent progress across iterations |

## Exit Condition

`python scripts/compare_drc.py --all` exits with code 0 — meaning delta=0 for ALL benchmark circuits.

## Important Constraints

- All commands must run under `nix develop --command`
- After `zig build`, always `cp zig-out/lib/libspout.so python/libspout.so`
- Do NOT modify comparison scripts to make results look better
- Do NOT delete or skip circuits that are hard to match
- One focused fix per iteration — don't try to fix everything at once
