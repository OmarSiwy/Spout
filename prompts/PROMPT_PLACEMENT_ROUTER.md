# Placement + Router Optimization: 0 DRC, LVS=true, Minimal PEX

> **Token saving**: Start every session with `/caveman` to use compressed output and save tokens.

## Goal

Improve Spout's placement and routing engines so that the output layout achieves:
1. **0 DRC violations** (highest priority) — `compare_drc.py` shows Spout total=0 for all circuits
2. **LVS=true** (high priority) — `compare_lvs.py` shows Spout=MATCH for all circuits
3. **Minimal PEX** (lower priority) — minimize parasitic R and C values

Priority order: DRC=0 > LVS=true >> PEX minimal. Never sacrifice DRC or LVS for better PEX.

## Architecture

- **Placer**: `src/placer/` — simulated annealing placement
- **Router**: `src/router/` — maze/channel routing with DRC awareness
- **DRC engine**: `src/characterize/drc.zig` — checks violations post-route
- **LVS engine**: `src/characterize/lvs.zig` + `ext2spice.zig` — connectivity verification
- **PEX engine**: `src/characterize/pex.zig` — parasitic extraction
- **Pipeline**: `python/pipeline.py` or FFI calls — orchestrates place→route→verify

## Iteration Protocol

Every iteration MUST follow this exact cycle:

### 1. Read State
```bash
cat prompts/progress_placer_router.txt 2>/dev/null || echo "First iteration"
```

### 2. Run Full Benchmark (ground truth)
Run all three comparison scripts to get the current state:
```bash
nix develop .#test --command bash -c "
  zig build -Doptimize=ReleaseFast && cp zig-out/lib/libspout.so python/libspout.so &&
  echo '=== DRC ===' && python scripts/compare_drc.py --all &&
  echo '=== LVS ===' && python scripts/compare_lvs.py --all &&
  echo '=== PEX ===' && python scripts/compare_pex.py --all
"
```
Record per-circuit: DRC violations (Spout column), LVS verdict, PEX R/C counts.

**The target is NOT matching MAGIC's DRC count — it's achieving 0 DRC violations from Spout's own checker.** MAGIC is the reference for DRC engine correctness (PROMPT_DRC.md), but here we want the router to produce clean layouts.

### 3. Research
- Look at the DRC violation breakdown: which rules are most commonly violated?
- For the circuit with the most violations, examine: Is it a routing issue (spacing, enclosure) or placement issue (overlap, too tight)?
- Read the relevant router/placer code to understand how it currently handles that rule
- Check if DRC repair pass exists (`use_repair` config flag) and if it helps

### 4. Implement ONE Fix
- Fix the router or placer to avoid the most common violation type
- Examples of fixes:
  - Increase minimum track spacing in router
  - Add DRC-aware via placement (enclosure checks)
  - Improve placement to leave more routing channels
  - Add post-route DRC repair pass
  - Fix net ordering in router to avoid shorts
- Primary files: `src/router/`, `src/placer/`
- Do NOT change `src/characterize/drc.zig` (that's the checker, not the fixer)

### 5. Test
```bash
nix develop .#test --command bash -c "
  zig build -Doptimize=ReleaseFast && cp zig-out/lib/libspout.so python/libspout.so &&
  echo '=== DRC ===' && python scripts/compare_drc.py --all &&
  echo '=== LVS ===' && python scripts/compare_lvs.py --all
"
```
- Did total DRC violations decrease?
- Did any LVS verdicts regress (MATCH → MISMATCH)?
- If both improved or DRC improved without LVS regression → good

### 6. Commit + Record Progress
```bash
git add src/router/ src/placer/
git commit -m "router: <what was fixed> — DRC violations X→Y, LVS still N/M MATCH"
```
Append to `prompts/progress_placer_router.txt`:
- Which violation type was addressed
- Before/after DRC counts per circuit
- LVS status (any regressions?)
- PEX impact if measured

## Key Files

| File | Purpose |
|------|---------|
| `src/router/` | Routing engine — track layout, via placement, net ordering |
| `src/placer/` | Placement engine — simulated annealing, cell positioning |
| `src/characterize/drc.zig` | DRC checker (read-only — do NOT modify here) |
| `src/characterize/lvs.zig` | LVS checker (read-only) |
| `src/characterize/pex.zig` | PEX extraction (read-only) |
| `src/pdk/` | PDK design rules — spacing, width, enclosure minimums |
| `scripts/compare_drc.py` | DRC comparison oracle |
| `scripts/compare_lvs.py` | LVS comparison oracle |
| `scripts/compare_pex.py` | PEX comparison oracle |
| `prompts/progress_placer_router.txt` | Persistent progress across iterations |

## Exit Condition

For ALL benchmark circuits:
1. `compare_drc.py --all` shows Spout total = 0 for every circuit
2. `compare_lvs.py --all` shows Spout = MATCH for every circuit
3. PEX values are as low as reasonably achievable (no hard threshold, but track improvement)

## Important Constraints

- Use `nix develop .#test --command` (needs magic/netgen for LVS)
- After `zig build`, always `cp zig-out/lib/libspout.so python/libspout.so`
- Do NOT modify DRC/LVS/PEX engines — only modify router and placer
- Do NOT modify comparison scripts
- NEVER sacrifice LVS correctness for DRC improvement
- NEVER sacrifice DRC for PEX improvement
- One focused fix per iteration — tackle the highest-impact DRC rule first
- If a routing change improves DRC but regresses LVS, revert it
