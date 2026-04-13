#!/usr/bin/env python3
"""Compare Spout in-engine DRC against MAGIC DRC for equivalence.

Goal: Spout's DRC should produce the SAME violations as MAGIC — not zero DRC,
but identical results.  The router isn't perfect, so both tools should agree
on what's wrong.

Runs each fixture through:
  1. Spout pipeline → GDS + in-engine DRC (total count + per-rule breakdown)
  2. MAGIC DRC on the same GDS → total count + per-rule breakdown
  3. Compares per-rule and total counts, reports delta

Uses pre-generated GDS from scripts/fixtures/ if available, otherwise generates
on the fly.

Usage:
    nix develop --command python scripts/compare_drc.py
    nix develop --command python scripts/compare_drc.py -c current_mirror
    nix develop --command python scripts/compare_drc.py --all
"""
from __future__ import annotations

import argparse
import os
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
_python_dir = str(ROOT / "python")
if _python_dir not in sys.path:
    sys.path.insert(0, _python_dir)

if "spout" not in sys.modules:
    import importlib.util
    spec = importlib.util.spec_from_file_location(
        "spout", str(ROOT / "python" / "__init__.py"),
        submodule_search_locations=[_python_dir],
    )
    if spec and spec.loader:
        mod = importlib.util.module_from_spec(spec)
        sys.modules["spout"] = mod
        spec.loader.exec_module(mod)

BENCHMARKS_DIR = ROOT / "fixtures" / "benchmark"
FIXTURES_DIR = ROOT / "scripts" / "fixtures"

DEFAULT_CIRCUITS = [
    "current_mirror",
    "diff_pair",
    "five_transistor_ota",
]


# ---------------------------------------------------------------------------
# Spout DRC
# ---------------------------------------------------------------------------

def run_spout_drc(netlist: pathlib.Path, output_dir: pathlib.Path) -> dict:
    """Run Spout pipeline and return DRC results with per-rule breakdown."""
    from spout.config import SpoutConfig, SaConfig
    from spout.pipeline import run_pipeline

    sa = SaConfig(max_iterations=500, cooling_rate=0.95, initial_temp=100.0)
    config = SpoutConfig(
        backend="klayout", pdk="sky130", sa_config=sa,
        use_ml=False, use_gradient=False, use_repair=False,
    )
    gds_path = str(output_dir / "test_output.gds")
    result = run_pipeline(str(netlist), config, output_path=gds_path)

    # Read per-rule breakdown from the diagnostic file Spout writes.
    # Format: "rule_name: count\n  gds_layer=N: count\n"
    # Only capture top-level rules (not indented gds_layer sub-breakdowns).
    per_rule: dict[str, int] = {}
    breakdown_file = pathlib.Path("/tmp/spout_drc_breakdown.txt")
    if breakdown_file.exists():
        for raw_line in breakdown_file.read_text().splitlines():
            if raw_line.startswith("  ") or raw_line.startswith("TOTAL"):
                continue
            raw_line = raw_line.strip()
            if ":" in raw_line:
                rule, count = raw_line.rsplit(":", 1)
                try:
                    per_rule[rule.strip()] = int(count.strip())
                except ValueError:
                    pass

    return {
        "total": result.drc_violations,
        "per_rule": per_rule,
        "gds_path": gds_path,
    }


# ---------------------------------------------------------------------------
# MAGIC DRC
# ---------------------------------------------------------------------------

def _categorize_magic_rule(desc: str) -> str:
    """Map a MAGIC rule description to a Spout DRC category."""
    d = desc.lower()
    if "minimum area" in d or "min area" in d:
        return "min_area"
    if "overlap" in d:
        return "min_enclosure"
    if "spacing" in d:
        return "min_spacing"
    if "width" in d:
        return "min_width"
    return "other"


def run_magic_drc(gds_path: pathlib.Path, top_cell: str) -> dict:
    """Run MAGIC DRC and return total + per-rule violation counts.

    `drc listall count` returns a list of sublists: {cell1 count1} {cell2 count2}
    `drc listall why` returns pairs: rule1 {rect_sublist1} rule2 {rect_sublist2}
      where each rect sublist element is {llx lly urx ury}, so llength = #rects.
    """
    pdk_root = os.environ.get("PDK_ROOT")
    if not pdk_root:
        return {"error": "PDK_ROOT not set"}
    if not shutil.which("magic"):
        return {"error": "magic not on PATH"}

    tech_file = pathlib.Path(pdk_root) / "sky130A" / "libs.tech" / "magic" / "sky130A.tech"

    tcl_script = f"""\
tech load {tech_file}
gds read {gds_path}
load {top_cell}
select top cell
drc check
drc catchup
set total 0
set cr [drc listall count]
foreach item $cr {{
    set cell [lindex $item 0]
    set cnt [lindex $item 1]
    if {{$cnt ne ""}} {{
        set total [expr {{$total + $cnt}}]
    }}
}}
puts "MAGIC_DRC_TOTAL: $total"
set wr [drc listall why]
foreach {{rule rects}} $wr {{
    set nrects [llength $rects]
    puts "MAGIC_WHY_RULE: $rule | $nrects"
}}
quit
"""
    try:
        result = subprocess.run(
            ["magic", "-dnull", "-noconsole"],
            input=tcl_script,
            capture_output=True,
            text=True,
            timeout=120,
        )
    except (subprocess.TimeoutExpired, OSError) as exc:
        return {"error": f"magic failed: {exc}"}

    # Parse total count from `drc listall count`
    total = 0
    for line in result.stdout.splitlines():
        if line.startswith("MAGIC_DRC_TOTAL:"):
            try:
                total = int(line.split(":", 1)[1].strip())
            except ValueError:
                pass

    # Parse per-rule rect counts from `drc listall why`
    per_rule: dict[str, int] = {}
    per_category: dict[str, int] = {}
    for line in result.stdout.splitlines():
        if line.startswith("MAGIC_WHY_RULE:"):
            raw = line.split(":", 1)[1].strip()
            if " | " in raw:
                rule, cnt = raw.rsplit(" | ", 1)
                rule = rule.strip()
                try:
                    n = int(cnt.strip())
                    per_rule[rule] = per_rule.get(rule, 0) + n
                    cat = _categorize_magic_rule(rule)
                    per_category[cat] = per_category.get(cat, 0) + n
                except ValueError:
                    pass

    return {
        "total": total,
        "per_rule": per_rule,
        "per_category": per_category,
    }


# ---------------------------------------------------------------------------
# Comparison
# ---------------------------------------------------------------------------

def compare_circuit(circuit: str, work_dir: pathlib.Path) -> dict:
    """Compare Spout vs MAGIC DRC for one circuit."""
    netlist = BENCHMARKS_DIR / f"{circuit}.spice"
    if not netlist.exists():
        return {"circuit": circuit, "error": f"netlist not found"}

    # Run Spout
    spout = run_spout_drc(netlist, work_dir)
    gds_path = pathlib.Path(spout["gds_path"])
    if not gds_path.exists():
        return {"circuit": circuit, "error": "GDS not generated"}

    # Run MAGIC on the same GDS
    magic = run_magic_drc(gds_path, circuit)
    if "error" in magic:
        return {"circuit": circuit, "error": f"MAGIC: {magic['error']}"}

    # Compare
    delta_total = spout["total"] - magic["total"]
    match_pct = (1 - abs(delta_total) / max(magic["total"], 1)) * 100

    return {
        "circuit": circuit,
        "spout_total": spout["total"],
        "magic_total": magic["total"],
        "delta": delta_total,
        "match_pct": match_pct,
        "spout_rules": spout["per_rule"],
        "magic_rules": magic["per_rule"],
        "magic_categories": magic.get("per_category", {}),
    }


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("-c", "--circuits", nargs="+", metavar="NAME",
                    help="Compare only these circuits")
    ap.add_argument("--all", action="store_true",
                    help="Compare all benchmarks")
    args = ap.parse_args()

    if args.all:
        circuits = sorted(
            p.stem for p in BENCHMARKS_DIR.glob("*.spice")
            if "_lvs" not in p.stem and "_pex" not in p.stem
        )
    else:
        circuits = args.circuits or DEFAULT_CIRCUITS

    print("=" * 80)
    print("DRC EQUIVALENCE COMPARISON: Spout vs MAGIC")
    print("=" * 80)
    print(f"Goal: delta=0 means in-engine DRC matches MAGIC exactly")
    print()

    results = []
    for circuit in circuits:
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = pathlib.Path(tmp)
            print(f"  {circuit} ...", end="", flush=True)
            r = compare_circuit(circuit, tmp_path)
            results.append(r)

            if "error" in r:
                print(f"  ERROR: {r['error']}")
            else:
                status = "MATCH" if r["delta"] == 0 else f"DELTA={r['delta']:+d}"
                print(f"  Spout={r['spout_total']}, MAGIC={r['magic_total']}, "
                      f"{status} ({r['match_pct']:.1f}%)")

    # Summary table
    print()
    print("=" * 80)
    print(f"{'Circuit':<30} {'Spout':>8} {'MAGIC':>8} {'Delta':>8} {'Match%':>8}")
    print("-" * 80)

    total_delta = 0
    matched = 0
    for r in results:
        if "error" in r:
            print(f"{r['circuit']:<30} {'ERROR':>8}")
            continue
        d = r["delta"]
        total_delta += abs(d)
        if d == 0:
            matched += 1
        print(f"{r['circuit']:<30} {r['spout_total']:>8} {r['magic_total']:>8} "
              f"{d:>+8} {r['match_pct']:>7.1f}%")

    valid = [r for r in results if "error" not in r]
    print("-" * 80)
    print(f"  {matched}/{len(valid)} circuits with exact match (delta=0)")
    print(f"  Total absolute delta: {total_delta}")
    print()

    # Per-rule comparison for each circuit
    for r in results:
        if "error" in r:
            continue

        # Categorized comparison (Spout rule types vs MAGIC categories)
        spout_rules = r.get("spout_rules", {})
        magic_cats = r.get("magic_categories", {})
        if spout_rules or magic_cats:
            print(f"\n  Category comparison: {r['circuit']}")
            print(f"  {'Category':<25} {'Spout':>8} {'MAGIC rects':>12} {'Note':>20}")
            print(f"  {'-'*65}")
            all_cats = sorted(set(spout_rules.keys()) | set(magic_cats.keys()))
            for cat in all_cats:
                s = spout_rules.get(cat, 0)
                m = magic_cats.get(cat, 0)
                note = "MATCH" if s == m else f"delta={s-m:+d}"
                print(f"  {cat:<25} {s:>8} {m:>12} {note:>20}")

        # Detailed MAGIC rules
        magic_rules = r.get("magic_rules", {})
        if magic_rules:
            print(f"\n  MAGIC detailed rules: {r['circuit']}")
            print(f"  {'Rule':<70} {'Rects':>8}")
            print(f"  {'-'*78}")
            for rule in sorted(magic_rules, key=lambda k: -magic_rules[k]):
                print(f"  {rule:<70} {magic_rules[rule]:>8}")

    sys.exit(0 if total_delta == 0 else 1)


if __name__ == "__main__":
    main()
