# Spout LVS — Next-Round Diagnostic Artifacts

**Context:** BUGS.md fixes S0-1, S0-2, S0-3, S0-4, S1-1, S1-2, S1-8 are now applied.
Baseline after fixes (diff_pair):

```
ROUTER STATS: astar_ok=8 astar_fail=0 L-DROP vert=0 horiz=0 l_horiz=0 l_vert=0
4324ms  DRC=0  LVS=✗  R=0 C=39
```

**Conclusion from counters:** A* routed every Steiner edge. No silent
`emitLShapeGridAware` drops. The LVS failure therefore cannot be S0-1
(silent drop) on diff_pair. The KLayout log only says
`ERROR : Netlists don't match`, without which nets or pins differ —
the diff itself lives in a `.lyrdb` report that the pipeline currently
discards with its `tempfile.TemporaryDirectory`.

To continue the diagnosis, I need the artifacts below, in priority order.

---

## 1. [HIGHEST] KLayout LVS diff (the actual mismatch)

The current pipeline's `DEBUG LVS details:` block only shows the KLayout
runtime log — not the netlist comparison. To get the real diff, run
LVS directly against a **persisted** GDS and emit a side-by-side report.

### 1a. Save the generated GDS to a known path

Run `scripts/benchmark.py` (or the pipeline directly) but keep the GDS.
Easiest: patch `run_benchmark` to copy `out.gds` into the project root.

```bash
# One-shot: rewrite benchmark to keep the GDS next to it
nix develop -c python - <<'PY'
import os, pathlib, sys
sys.path.insert(0, "python")
from spout.config import SpoutConfig
from spout.main import run_pipeline
cfg = SpoutConfig()
out = pathlib.Path("diff_pair.gds").resolve()
run_pipeline("fixtures/benchmark/diff_pair.spice", cfg, output_path=str(out))
print(f"wrote {out}")
PY
```

Paste back: confirmation that `diff_pair.gds` exists and its byte size.

### 1b. Run KLayout LVS manually and save the report

```bash
nix develop -c bash -c '
  SCHEMATIC=fixtures/benchmark/diff_pair.spice
  GDS=diff_pair.gds
  LVS_SCRIPT=$PDK_ROOT/sky130A/libs.tech/klayout/lvs/sky130.lylvs
  klayout -b -r "$LVS_SCRIPT" \
    -rd input=$(readlink -f $GDS) \
    -rd schematic=$(readlink -f $SCHEMATIC) \
    -rd topcell=diff_pair \
    -rd report=diff_pair.lyrdb \
    2>&1 | tee diff_pair.lvs.log
'
```

Paste back:
- `diff_pair.lvs.log` (full KLayout stdout+stderr)
- `diff_pair.lyrdb` (the XML LVS report — contains the actual per-net
  and per-device mismatch). If the file is large, paste the **first
  200 lines** and the **last 200 lines**.

### 1c. Pull the extracted netlist from KLayout

The LVS script writes `diff_pair_extracted.cir` into its own working
directory. After running 1b, locate and paste it:

```bash
nix develop -c bash -c '
  find / -name diff_pair_extracted.cir 2>/dev/null | head -5
'
```

Paste back: the contents of `diff_pair_extracted.cir`. This is
KLayout's view of the circuit, and comparing it to
`fixtures/benchmark/diff_pair.spice` will show immediately which net
or device is wrong.

---

## 2. [HIGH] ASCII dump of `diff_pair.gds`

Write this helper once, then run it after 1a succeeds.

```python
# dump_gds.py
import pya, os, sys
inp = os.environ["input"]; out = os.environ["output"]
ly = pya.Layout(); ly.read(inp)
with open(out, "w") as f:
    for cell in ly.each_cell():
        f.write(f"CELL {cell.name}\n")
        for li in ly.layer_indexes():
            info = ly.get_info(li)
            for sh in cell.shapes(li).each():
                if sh.is_box():
                    b = sh.box
                    f.write(f"  BOX L={info.layer}/{info.datatype} "
                            f"({b.left},{b.bottom})-({b.right},{b.top})\n")
                elif sh.is_path():
                    p = sh.path
                    f.write(f"  PATH L={info.layer}/{info.datatype} "
                            f"w={p.width} pts={list(p.each_point())}\n")
                elif sh.is_polygon():
                    poly = sh.polygon
                    f.write(f"  POLY L={info.layer}/{info.datatype} "
                            f"pts={[(p.x, p.y) for p in poly.each_point_hull()]}\n")
                elif sh.is_text():
                    t = sh.text
                    f.write(f"  TEXT L={info.layer}/{info.datatype} "
                            f"({t.x},{t.y}) \"{t.string}\"\n")
```

```bash
nix develop -c bash -c '
  input=diff_pair.gds output=diff_pair.gds.txt klayout -b -r dump_gds.py
  wc -l diff_pair.gds.txt
'
```

Paste back: the full `diff_pair.gds.txt`.

This tells me:
- Are TEXT labels present on every pin position?
- On which layers? (expect `68/5` for M1 pins, `67/5` for LI)
- Does the M1/M2/M3 routing actually connect each named net end-to-end?
- Are there orphan fragments (unnamed metal between pins)?

---

## 3. [HIGH] Magic PEX netlist (second opinion on connectivity)

```bash
nix develop -c bash -c '
  mkdir -p /tmp/mag_pex && cd /tmp/mag_pex
  cp $OLDPWD/diff_pair.gds .
  magic -dnull -noconsole -T $PDK_ROOT/sky130A/libs.tech/magic/sky130A.tech <<EOF
gds read diff_pair.gds
load diff_pair
select top cell
extract all
ext2spice hierarchy on
ext2spice format ngspice
ext2spice cthresh 0
ext2spice rthresh 0
ext2spice
quit -noprompt
EOF
  cat diff_pair.spice
'
```

Paste back: the Magic-extracted `diff_pair.spice` (from `/tmp/mag_pex/`).

If Magic says "connected" but KLayout says "fragmented", the bug is
in KLayout label attachment (layer number, datatype, or label
positioning). If both say fragmented, the bug is geometric.

---

## 4. [MEDIUM] Placer device positions

Need for verifying S1-5 grid alignment.

```bash
nix develop -c python - <<'PY'
import sys, pathlib
sys.path.insert(0, "python")
from spout.parser import parse_spice
from spout.placer import place_devices
from spout.config import SpoutConfig
cfg = SpoutConfig()
netlist = parse_spice("fixtures/benchmark/diff_pair.spice")
placed = place_devices(netlist, cfg.pdk)
for i, d in enumerate(placed.devices):
    print(f"dev[{i}] type={d.type} name={d.name} "
          f"pos=({d.x:.3f},{d.y:.3f}) dim=({d.w:.3f},{d.l:.3f}) m={d.mult}")
PY
```

(The exact API may differ — if the snippet fails, paste the error and
I'll adjust it.)

Paste back: device positions and dimensions for diff_pair.

---

## 5. [MEDIUM] Pin table dump

Same module path — expose `PinEdgeArrays` after `computePinOffsets`:

```bash
nix develop -c python - <<'PY'
# TODO: route this through the actual Python bindings used by the
# pipeline.  The goal is to print, per pin:
#   pin[i]: dev=<idx> term=<gate/drain/source/body> net=<name>
#           pos_offset=(x,y) abs_pos=(X,Y)
PY
```

Alternatively: add a `dbgPrint` loop to `src/core/pin_edge_arrays.zig`'s
`computePinOffsets` that dumps the table on the first call, rebuild,
rerun `scripts/benchmark.py -c diff_pair`, and paste the dump.

I'm looking for:
- Duplicates (S1-7: `pinNetForTerminal` returns only first match)
- Missing body terminals
- Wrong net assignments (e.g., both M3 sources on `tail` rather than `VSS`)

---

## 6. [LOWER] Full benchmark regression

```bash
nix develop -c python scripts/benchmark.py 2>&1 | tee /tmp/full.log
grep -E "LVS=" /tmp/full.log | awk '{print $NF}' | sort | uniq -c
```

Paste back: the summary table plus the `grep` output. Tells me whether
the signal-first net ordering (S1-8) or any other fix caused a
regression on a circuit that previously passed.

---

## 7. [LOWER] A* movement generation

Needed only if the above artifacts indicate multi-layer jumps.

```bash
nix develop -c bash -c '
  grep -n "layer\s*+\s*1\|layer\s*-\s*1\|\\.layer\s*=" src/router/astar.zig
'
```

Paste back: the output.

---

## Summary — minimum I need to make the next decision

If you can only paste **one** thing, make it item **1b** (the KLayout
LVS report + log). Item **2** (GDS dump) is almost as useful.
Everything else is confirmatory.

---

# Update — 2026-04-16 : post `isNearTarget` removal

Progression of cap count:
- Baseline (S0-* + S1-* fixes applied):   C=39
- After pin→AP stitch in `routeNet`:       C=12
- After `commitPath` bridge emission:      C=12 (but introduced M1 shorts)
- After `isNearTarget` removed in A*:      **C=9** (current)
- `astar_fail=0` throughout.

LVS artifacts (see `/tmp/diff_pair_report.lyrdb`, `/tmp/diff_pair.gds.txt`):

## Remaining mismatches (4 net errors → C=9)

From `Z(...L(...))` in the lyrdb:

```
M(E B('Net INN is not matching any net from reference netlist'))
M(E B('Net VSS is not matching any net from reference netlist'))
M(E B('Net OUTP is not matching any net from reference netlist'))
M(E B('Net BIAS,VSS is not matching any net from reference netlist'))
```

And the extracted device connectivity (devices D1–D3 in layout):

| Dev | W (extracted) | S           | G   | D     | B           |
| --- | ------------- | ----------- | --- | ----- | ----------- |
| D1  | 8µm (was m=2) | VSS (net 5) | net6 "BIAS,VSS" | **OUTP (net 1)** | net6 |
| D2  | 2µm           | **OUTP (1)** | INN (4) | **OUTP (1)** | net6 |
| D3  | 2µm           | **OUTP (1)** | INP (2) | OUTN (3) | net6 |

Schematic expects:

| Dev | W | S | G | D | B |
| --- | -- | --- | --- | --- | --- |
| D3 (W=8) | tail device | VSS | BIAS | **TAIL** | VSS |
| D1 (W=2) | | **TAIL** | INP | OUTN | VSS |
| D2 (W=2) | | **TAIL** | INN | OUTP | VSS |

## Root cause analysis

Two independent shorts + one label attribution bug:

### A. **OUTP↔TAIL short.**
Layout net 1 (labeled "OUTP") carries TAIL connectivity of all three
devices (W=8 drain + both W=2 sources). The OUTP label lands on the
TAIL wire because the routed TAIL net physically touches the OUTP M1
pad of one W=2 device. KLayout then names the merged wire by whichever
label it finds first ("OUTP" wins alphabetically / spatially), so LVS
reports "net 1 = OUTP" even though the connectivity shape is actually
TAIL∪OUTP.

One of the W=2 devices (D2) has S=D=1 — drain and source both landing
on the merged OUTP∪TAIL net. That is the smoking gun: the TAIL wire
bridged onto the OUTP M1 pad of that device.

Candidate mechanism: A* path routing TAIL between W=8 drain
(x=-3830, y=16132) and a W=2 source at (x=250, y=11732) traverses the
column x=250 on M1/M2, crosses the M2.drain M1 landing pad at
(10..260, 12469..12719) which is also the OUTP pad. Pad overlap =
electrical short.

### B. **BIAS↔VSS short.**
Layout net 6 is extracted as a single net with label "BIAS,VSS" (both
labels land on the same electrical region). BIAS wire from the W=8
gate (at x=-3830, y=16492) is merging with VSS somewhere in the
sea-of-VSS routes. GDS dump shows BIAS label at (-4065, 16497) on
68/5, only one label, and a 69/20 M2 run from (-430,16492) to
(-3830,16492) which... sits directly on top of M2 VSS territory.

Many of the 69/5 labels near (-430,*) and (-3830,*) are also "VSS",
which suggests the M2 BIAS route and the M2 VSS rail are in the same
column/track and have been claimed/merged.

### C. **VSS fragmentation.**
Layout net 5 (labeled VSS) is separate from the merged net 6. So VSS
has at least two disjoint named regions: one is the W=8 source (net 5,
correctly VSS) and the other is everything merged with BIAS (net 6,
"BIAS,VSS"). LVS can't reconcile: "which net is VSS?"

## Geometry evidence

From `/tmp/diff_pair.gds.txt`:

- W=8 device centered at x≈0 (diff 65/20 at (-3865,16162)-(4135,16832)).
  Body tap at x=-3830 y=16132 (BIAS label nearby, line 271).
- BIAS M2 trunk: line 220-222 —
  `PATH L=69/20 (-430,16492)-(-3830,16492)` (M2 long run),
  `PATH L=69/20 (-3830,16492)-(-3830,16152)` (M2 drop to W=8 gate pad).
- VSS M2 trunk: line 218-219 —
  `PATH L=69/20 (-430,11392)-(-430,15812)...-(-430,16492)`.
  The BIAS trunk's x=-430 start point coincides with the VSS trunk's
  x=-430 column. The VSS M2 path reaches y=16492 at x=-430, **exactly
  the start of the BIAS M2 path**. Connected through a shared M2 cell
  at (-430, 16492). Short.

Same kind of analysis explains A: the TAIL M2 at x=250 running
y=11532→y=12072 bridges the OUTP M1 pad at (10..260, 12469..12719)
through an mcon/via1 stack landing at x=250 y=12469.

## Fix direction

Both shorts share a cause: **different nets routed into the same grid
cell without honouring `net_owned` exclusivity**. Likely the
bridge emission in `commitPath` (added this session) writes into cells
without checking ownership, or A* reuses cells already claimed by a
prior-routed net because `claimCell`/`claimNodeSpan` doesn't re-mark
every cell the path actually traverses (especially after the pin→AP
stitch and bridge additions).

Next debugging step: instrument `claimCell` / `claimNodeSpan` /
`routes.append` to dump `(net, layer, x1,y1,x2,y2, prior_owner)` for
every write that crosses a cell already owned by a different net.
Expect to see three hits corresponding to the three observed shorts:

1. TAIL writes into M1 cell at (10..260, 12469..12719) — previously OUTP.
2. BIAS writes into M2 cell at (-430, 16492) — previously VSS.
3. One more between VSS fragments.

Code pointers:
- `src/router/detailed.zig` stitch logic (routeNet, pre tree.build)
- `src/router/detailed.zig` bridge logic (commitPath, via transition)
- `src/router/grid.zig` `claimCell` / `claimNodeSpan`
- `src/core/route_arrays.zig` `append`

## Open question to investigate

Does `routes.append` update grid ownership, or only record the
geometry? If only geometry, then the stitch / bridge emits wires that
are invisible to the next net's A*. Physical layout has them but grid
thinks cell is free → next net routes into the same cell → short.

If that's the case, every `routes.append` from outside `commitPath`
also needs a corresponding `claimCell`/`claimNodeSpan` call.
