#!/usr/bin/env python3
"""Spout pipeline benchmark runner.

Runs the full layout pipeline on every input benchmark (excluding *_lvs* and
*_pex* extraction artifacts) and prints a per-phase timing table plus a
bottleneck summary so you can see which stage to optimise next.

Usage:
    python scripts/benchmark.py                  # all benchmarks
    python scripts/benchmark.py -n 5            # first 5 (alphabetical)
    python scripts/benchmark.py -c current_mirror diff_pair
    python scripts/benchmark.py --sort route    # sort table by routing time
    python scripts/benchmark.py --no-pex        # skip PEX (faster runs)
"""

from __future__ import annotations

import argparse
import logging
import os
import pathlib
import sys
import tempfile

# Make sure `python/` is on the path whether you run from project root or scripts/.
_ROOT = pathlib.Path(__file__).resolve().parent.parent
_python_dir = str(_ROOT / "python")
if _python_dir not in sys.path:
    sys.path.insert(0, _python_dir)

# Register "python/" as the "spout" package so `from spout.X import Y` works
# outside of pytest (which does this via conftest.py).
if "spout" not in sys.modules:
    import importlib.util
    spec = importlib.util.spec_from_file_location(
        "spout",
        str(_ROOT / "python" / "__init__.py"),
        submodule_search_locations=[_python_dir],
    )
    if spec and spec.loader:
        mod = importlib.util.module_from_spec(spec)
        sys.modules["spout"] = mod
        spec.loader.exec_module(mod)

from spout.config import SpoutConfig
from spout.pipeline import PipelineResult, StageTimings, run_pipeline

logging.disable(logging.CRITICAL)  # silence pipeline logger; we render our own output

# ── Phase metadata ────────────────────────────────────────────────────────────

PHASES = [
    ("parse",       "Parse"),
    ("constraints", "Constr"),
    ("placement",   "Place"),
    ("routing",     "Route"),
    ("export",      "Export"),
    ("drc",         "DRC"),
    ("lvs",         "LVS"),
    ("pex",         "PEX"),
]

# ── Benchmark discovery ───────────────────────────────────────────────────────

def collect_benchmarks(root: pathlib.Path) -> list[pathlib.Path]:
    bm_dir = root / "fixtures" / "benchmark"
    return sorted(
        p for p in bm_dir.glob("*.spice")
        if "_lvs" not in p.stem and "_pex" not in p.stem
    )

# ── Runner ────────────────────────────────────────────────────────────────────

def run_benchmark(spice: pathlib.Path, cfg: SpoutConfig) -> tuple[PipelineResult, str | None]:
    with tempfile.TemporaryDirectory() as d:
        out = os.path.join(d, "out.gds")
        try:
            r = run_pipeline(str(spice), cfg, output_path=out)
            return r, None
        except Exception as exc:
            return None, str(exc)

# ── Formatting ────────────────────────────────────────────────────────────────

def bar(value: float, total: float, width: int = 20) -> str:
    frac = value / total if total > 0 else 0
    filled = round(frac * width)
    return "█" * filled + "░" * (width - filled)

def fmt_ms(s: float) -> str:
    ms = s * 1000
    if ms >= 10_000:
        return f"{ms/1000:.1f}s"
    return f"{ms:.0f}ms"

def fmt_pct(part: float, total: float) -> str:
    if total <= 0:
        return " —"
    return f"{100*part/total:4.0f}%"

# ── Main ──────────────────────────────────────────────────────────────────────

def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("-c", "--circuits", nargs="+", metavar="NAME",
                    help="Run only these circuit names (stem, no .spice)")
    ap.add_argument("-n", "--limit", type=int, default=0,
                    help="Run at most N benchmarks (0 = all)")
    ap.add_argument("--sort", default="total",
                    choices=["name","parse","constraints","placement","routing",
                             "route","export","drc","lvs","pex","total","drc_count"],
                    help="Column to sort output table by (default: total)")
    ap.add_argument("--no-pex", action="store_true",
                    help="Skip PEX extraction (faster runs)")
    ap.add_argument("--pdk", default="sky130", choices=["sky130","gf180","ihp130"])
    args = ap.parse_args()

    all_spice = collect_benchmarks(_ROOT)
    if args.circuits:
        all_spice = [p for p in all_spice if p.stem in args.circuits]
    if args.limit:
        all_spice = all_spice[:args.limit]

    if not all_spice:
        print("No benchmarks found.")
        sys.exit(1)

    cfg = SpoutConfig(pdk=args.pdk)

    rows: list[dict] = []
    errors: list[tuple[str, str]] = []

    total_circuits = len(all_spice)
    for idx, spice in enumerate(all_spice, 1):
        name = spice.stem
        print(f"[{idx:2d}/{total_circuits}] {name} ...", end="", flush=True)
        result, err = run_benchmark(spice, cfg)
        if err:
            print(f"  FAILED: {err}")
            errors.append((name, err))
            continue
        t = result.timings
        row = {
            "name":        name,
            "devices":     result.num_devices,
            "nets":        result.num_nets,
            "routes":      result.num_routes,
            "parse":       t.parse,
            "constraints": t.constraints,
            "placement":   t.placement,
            "routing":     t.routing,
            "export":      t.export,
            "drc":         t.drc,
            "lvs":         t.lvs,
            "pex":         t.pex,
            "total":       t.total,
            "drc_count":   result.drc_violations,
            "lvs_ok":      result.lvs_clean,
            "pex_res":     result.pex_parasitic_res,
            "pex_cap":     result.pex_parasitic_caps,
        }
        rows.append(row)
        print(f"  {fmt_ms(t.total):>7}  DRC={result.drc_violations}  LVS={'✓' if result.lvs_clean else '✗'}  R={result.pex_parasitic_res} C={result.pex_parasitic_caps}")

    if not rows:
        print("\nAll benchmarks failed.")
        sys.exit(1)

    # Sort
    sort_key = args.sort if args.sort != "route" else "routing"
    rows.sort(key=lambda r: r.get(sort_key, r["total"]))

    # ── Timing table ──────────────────────────────────────────────────────────
    print()
    print("=" * 110)
    print("PHASE TIMINGS")
    print("=" * 110)

    # Header
    ph_labels = [label for _, label in PHASES]
    name_w = max(len(r["name"]) for r in rows)
    name_w = max(name_w, 8)
    hdr = f"{'Circuit':<{name_w}}  {'Dev':>4} {'Net':>4} {'Rte':>4}"
    for _, label in PHASES:
        hdr += f"  {label:>7}"
    hdr += f"  {'Total':>8}  {'DRC':>5} {'LVS':>4} {'Res':>4} {'Cap':>5}"
    print(hdr)
    print("-" * len(hdr))

    for r in rows:
        line = f"{r['name']:<{name_w}}  {r['devices']:>4} {r['nets']:>4} {r['routes']:>4}"
        for key, _ in PHASES:
            line += f"  {fmt_ms(r[key]):>7}"
        line += f"  {fmt_ms(r['total']):>8}"
        line += f"  {r['drc_count']:>5} {'✓' if r['lvs_ok'] else '✗':>4} {r['pex_res']:>4} {r['pex_cap']:>5}"
        print(line)

    print("-" * len(hdr))

    # Averages row
    n = len(rows)
    avg_line = f"{'AVERAGE':<{name_w}}  {'':>4} {'':>4} {'':>4}"
    for key, _ in PHASES:
        avg = sum(r[key] for r in rows) / n
        avg_line += f"  {fmt_ms(avg):>7}"
    avg_total = sum(r["total"] for r in rows) / n
    avg_line += f"  {fmt_ms(avg_total):>8}"
    print(avg_line)

    # ── Bottleneck analysis ───────────────────────────────────────────────────
    print()
    print("=" * 60)
    print("BOTTLENECK ANALYSIS  (average time per phase)")
    print("=" * 60)

    phase_avgs = {key: sum(r[key] for r in rows) / n for key, _ in PHASES}
    total_avg  = sum(phase_avgs.values())
    sorted_phases = sorted(phase_avgs.items(), key=lambda x: x[1], reverse=True)

    for key, avg_s in sorted_phases:
        label = next(lbl for k, lbl in PHASES if k == key)
        b = bar(avg_s, total_avg, width=30)
        print(f"  {label:<8} {fmt_ms(avg_s):>8}  {fmt_pct(avg_s, total_avg)}  {b}")

    print()
    top_key, top_val = sorted_phases[0]
    top_label = next(lbl for k, lbl in PHASES if k == top_key)
    print(f"  Bottleneck: {top_label} ({fmt_ms(top_val)}/circuit avg, {fmt_pct(top_val, total_avg)} of pipeline)")

    # ── Error summary ─────────────────────────────────────────────────────────
    if errors:
        print()
        print(f"FAILED ({len(errors)}):")
        for name, err in errors:
            print(f"  {name}: {err}")

    print()
    print(f"Ran {n}/{total_circuits} benchmarks.")


if __name__ == "__main__":
    main()
