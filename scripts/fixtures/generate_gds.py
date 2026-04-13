#!/usr/bin/env python3
"""Generate GDS files from benchmark SPICE fixtures.

Runs the Spout pipeline on each benchmark circuit and saves the GDS output
into scripts/fixtures/<circuit>.gds for downstream comparison scripts.

Usage:
    nix develop --command python scripts/fixtures/generate_gds.py
    nix develop --command python scripts/fixtures/generate_gds.py -c current_mirror diff_pair
"""
from __future__ import annotations

import argparse
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent.parent
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
FIXTURES_DIR = pathlib.Path(__file__).resolve().parent


# Small circuits that run fast — good default set for comparison scripts.
DEFAULT_CIRCUITS = [
    "current_mirror",
    "diff_pair",
    "five_transistor_ota",
    "folded_cascode",
    "sar_adc_comparator",
]


def collect_circuits(names: list[str] | None) -> list[str]:
    """Return circuit names to generate, validating each exists."""
    circuits = names or DEFAULT_CIRCUITS
    valid = []
    for c in circuits:
        spice = BENCHMARKS_DIR / f"{c}.spice"
        if not spice.exists():
            print(f"  SKIP {c} (netlist not found)")
            continue
        valid.append(c)
    return valid


def generate_gds(circuit: str) -> pathlib.Path | None:
    """Run Spout pipeline on a circuit and return the GDS path."""
    from spout.config import SpoutConfig, SaConfig
    from spout.pipeline import run_pipeline

    netlist = BENCHMARKS_DIR / f"{circuit}.spice"
    gds_path = FIXTURES_DIR / f"{circuit}.gds"

    sa = SaConfig(max_iterations=500, cooling_rate=0.95, initial_temp=100.0)
    config = SpoutConfig(
        backend="klayout", pdk="sky130", sa_config=sa,
        use_ml=False, use_gradient=False, use_repair=False,
    )
    try:
        result = run_pipeline(str(netlist), config, output_path=str(gds_path))
        if result.error:
            print(f"  FAILED {circuit}: {result.error}")
            return None
        return gds_path
    except Exception as exc:
        print(f"  FAILED {circuit}: {exc}")
        return None


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("-c", "--circuits", nargs="+", metavar="NAME",
                    help="Generate only these circuits (default: small set)")
    ap.add_argument("--all", action="store_true",
                    help="Generate all benchmarks (not just default small set)")
    args = ap.parse_args()

    if args.all:
        all_spice = sorted(
            p.stem for p in BENCHMARKS_DIR.glob("*.spice")
            if "_lvs" not in p.stem and "_pex" not in p.stem
        )
        circuits = collect_circuits(all_spice)
    else:
        circuits = collect_circuits(args.circuits)

    if not circuits:
        print("No circuits to generate.")
        sys.exit(1)

    print(f"Generating GDS for {len(circuits)} circuits into {FIXTURES_DIR}")
    print("=" * 60)

    generated = 0
    for circuit in circuits:
        print(f"  [{generated+1}/{len(circuits)}] {circuit} ...", end="", flush=True)
        gds = generate_gds(circuit)
        if gds:
            print(f"  OK ({gds.stat().st_size} bytes)")
            generated += 1
        else:
            print()

    print(f"\nGenerated {generated}/{len(circuits)} GDS files.")


if __name__ == "__main__":
    main()
