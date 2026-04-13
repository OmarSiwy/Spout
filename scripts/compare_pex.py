#!/usr/bin/env python3
"""Compare Spout in-engine PEX against MAGIC ext2spice for equivalence.

Goal: Spout's PEX should produce the SAME parasitic elements as MAGIC — not
zero parasitics, but equivalent extraction results.

Compares:
  - Element counts (R, C)
  - Total values (Ohm, fF)
  - Per-net breakdown where possible

Usage:
    nix develop --command python scripts/compare_pex.py
    nix develop --command python scripts/compare_pex.py -c current_mirror
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

DEFAULT_CIRCUITS = [
    "current_mirror",
    "diff_pair",
    "five_transistor_ota",
    "folded_cascode",
    "sar_adc_comparator",
]


# ---------------------------------------------------------------------------
# SPICE value parsing
# ---------------------------------------------------------------------------

def parse_spice_value(s: str) -> float:
    """Parse a SPICE numeric value with optional suffix (f, p, n, u, m, k, meg)."""
    s = s.strip().lower()
    multipliers = {
        "f": 1e-15, "p": 1e-12, "n": 1e-9, "u": 1e-6,
        "m": 1e-3, "k": 1e3, "meg": 1e6, "g": 1e9, "t": 1e12,
    }
    for suffix, mult in sorted(multipliers.items(), key=lambda x: -len(x[0])):
        if s.endswith(suffix):
            return float(s[: -len(suffix)]) * mult
    return float(s)


# ---------------------------------------------------------------------------
# Spout PEX
# ---------------------------------------------------------------------------

def run_spout_pex(netlist: pathlib.Path, output_dir: pathlib.Path) -> dict:
    """Run Spout pipeline + PEX and return detailed results."""
    from spout.config import SpoutConfig, SaConfig
    from spout.pipeline import run_pipeline

    sa = SaConfig(max_iterations=500, cooling_rate=0.95, initial_temp=100.0)
    config = SpoutConfig(
        backend="klayout", pdk="sky130", sa_config=sa,
        use_ml=False, use_gradient=False, use_repair=False,
    )
    gds_path = str(output_dir / "test_output.gds")
    result = run_pipeline(str(netlist), config, output_path=gds_path)

    assessment = result.pex_assessment
    return {
        "num_res": result.pex_parasitic_res,
        "num_cap": result.pex_parasitic_caps,
        "total_res_ohm": assessment.total_res_ohm if assessment else 0.0,
        "total_cap_ff": assessment.total_cap_ff if assessment else 0.0,
        "gds_path": gds_path,
    }


# ---------------------------------------------------------------------------
# MAGIC PEX
# ---------------------------------------------------------------------------

def run_magic_pex(gds_path: pathlib.Path, top_cell: str, work_dir: pathlib.Path) -> dict:
    """Run MAGIC ext2spice and return parsed parasitic results."""
    pdk_root = os.environ.get("PDK_ROOT")
    if not pdk_root:
        return {"error": "PDK_ROOT not set"}
    if not shutil.which("magic"):
        return {"error": "magic not on PATH"}

    tech_file = (
        pathlib.Path(pdk_root) / "sky130A" / "libs.tech" / "magic" / "sky130A.tech"
    )

    tcl_script = f"""\
tech load {tech_file}
gds read {gds_path}
load {top_cell}
select top cell
extract all
ext2spice format ngspice
ext2spice cthresh 0
ext2spice rthresh 0
ext2spice
puts "EXT2SPICE_DONE"
quit
"""
    try:
        result = subprocess.run(
            ["magic", "-dnull", "-noconsole"],
            input=tcl_script,
            capture_output=True,
            text=True,
            timeout=120,
            cwd=str(work_dir),
        )
    except (subprocess.TimeoutExpired, OSError) as exc:
        return {"error": f"magic failed: {exc}"}

    if "EXT2SPICE_DONE" not in result.stdout:
        return {"error": f"ext2spice did not complete (rc={result.returncode})"}

    # Find the output SPICE file
    spice_path = None
    for name in [f"{top_cell}.spice", f"{top_cell.lower()}.spice"]:
        p = work_dir / name
        if p.exists():
            spice_path = p
            break
    if spice_path is None:
        candidates = sorted(work_dir.glob("*.spice"))
        if candidates:
            spice_path = candidates[0]
        else:
            return {"error": "MAGIC did not produce a .spice file"}

    return parse_magic_spice(spice_path)


def parse_magic_spice(spice_path: pathlib.Path) -> dict:
    """Parse MAGIC ext2spice SPICE output for R/C elements with per-net detail."""
    resistors: list[dict] = []
    capacitors: list[dict] = []

    for line in spice_path.read_text(errors="replace").splitlines():
        s = line.strip()
        if not s or s.startswith("*") or s.startswith("."):
            continue
        parts = s.split()
        first = parts[0][0].upper()

        if first == "R" and len(parts) >= 4:
            try:
                resistors.append({
                    "name": parts[0],
                    "net_a": parts[1],
                    "net_b": parts[2],
                    "value": parse_spice_value(parts[3]),
                })
            except (ValueError, IndexError):
                pass
        elif first == "C" and len(parts) >= 4:
            try:
                capacitors.append({
                    "name": parts[0],
                    "net_a": parts[1],
                    "net_b": parts[2],
                    "value_f": parse_spice_value(parts[3]),
                })
            except (ValueError, IndexError):
                pass

    total_r = sum(r["value"] for r in resistors)
    total_c_ff = sum(c["value_f"] * 1e15 for c in capacitors)

    # Per-net aggregation for capacitors (substrate + coupling)
    net_caps: dict[str, float] = {}
    for c in capacitors:
        for net in [c["net_a"], c["net_b"]]:
            if net.lower() not in ("0", "gnd", "vss"):
                net_caps[net] = net_caps.get(net, 0.0) + c["value_f"] * 1e15

    # Per-net aggregation for resistors
    net_res: dict[str, float] = {}
    for r in resistors:
        for net in [r["net_a"], r["net_b"]]:
            net_res[net] = net_res.get(net, 0.0) + r["value"]

    return {
        "num_res": len(resistors),
        "num_cap": len(capacitors),
        "total_res_ohm": total_r,
        "total_cap_ff": total_c_ff,
        "net_caps_ff": net_caps,
        "net_res_ohm": net_res,
        "resistors": resistors,
        "capacitors": capacitors,
    }


# ---------------------------------------------------------------------------
# Comparison
# ---------------------------------------------------------------------------

def ratio_str(a: float, b: float) -> str:
    """Format a/b ratio with status tag."""
    if b == 0 and a == 0:
        return "1.000x MATCH"
    if b == 0:
        return "inf"
    r = a / b
    if 0.95 <= r <= 1.05:
        tag = " MATCH"
    elif 0.5 <= r <= 2.0:
        tag = " CLOSE"
    else:
        tag = " OFF"
    return f"{r:.3f}x{tag}"


def compare_circuit(circuit: str, work_dir: pathlib.Path) -> dict:
    """Compare Spout vs MAGIC PEX for one circuit."""
    netlist = BENCHMARKS_DIR / f"{circuit}.spice"
    if not netlist.exists():
        return {"circuit": circuit, "error": "netlist not found"}

    # Run Spout PEX
    spout = run_spout_pex(netlist, work_dir)
    gds_path = pathlib.Path(spout["gds_path"])
    if not gds_path.exists():
        return {"circuit": circuit, "error": "GDS not generated"}

    # Run MAGIC PEX on the same GDS
    magic_work = work_dir / "magic"
    magic_work.mkdir(exist_ok=True)
    magic = run_magic_pex(gds_path, circuit, magic_work)
    if "error" in magic:
        return {"circuit": circuit, "error": f"MAGIC: {magic['error']}"}

    # Compute deltas
    delta_res_count = spout["num_res"] - magic["num_res"]
    delta_cap_count = spout["num_cap"] - magic["num_cap"]
    delta_res_ohm = spout["total_res_ohm"] - magic["total_res_ohm"]
    delta_cap_ff = spout["total_cap_ff"] - magic["total_cap_ff"]

    return {
        "circuit": circuit,
        "spout_num_res": spout["num_res"],
        "spout_num_cap": spout["num_cap"],
        "spout_total_res": spout["total_res_ohm"],
        "spout_total_cap": spout["total_cap_ff"],
        "magic_num_res": magic["num_res"],
        "magic_num_cap": magic["num_cap"],
        "magic_total_res": magic["total_res_ohm"],
        "magic_total_cap": magic["total_cap_ff"],
        "delta_res_count": delta_res_count,
        "delta_cap_count": delta_cap_count,
        "delta_res_ohm": delta_res_ohm,
        "delta_cap_ff": delta_cap_ff,
        "ratio_res_count": ratio_str(spout["num_res"], magic["num_res"]),
        "ratio_cap_count": ratio_str(spout["num_cap"], magic["num_cap"]),
        "ratio_res_ohm": ratio_str(spout["total_res_ohm"], magic["total_res_ohm"]),
        "ratio_cap_ff": ratio_str(spout["total_cap_ff"], magic["total_cap_ff"]),
        "magic_net_caps": magic.get("net_caps_ff", {}),
        "magic_net_res": magic.get("net_res_ohm", {}),
    }


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("-c", "--circuits", nargs="+", metavar="NAME")
    ap.add_argument("--all", action="store_true")
    ap.add_argument("--verbose", "-v", action="store_true",
                    help="Show per-net breakdown from MAGIC")
    args = ap.parse_args()

    if args.all:
        circuits = sorted(
            p.stem for p in BENCHMARKS_DIR.glob("*.spice")
            if "_lvs" not in p.stem and "_pex" not in p.stem
        )
    else:
        circuits = args.circuits or DEFAULT_CIRCUITS

    print("=" * 95)
    print("PEX EQUIVALENCE COMPARISON: Spout vs MAGIC")
    print("=" * 95)
    print("Goal: element counts and total values should match (ratio ~1.0x)")
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
                print(
                    f"  R: {r['spout_num_res']} vs {r['magic_num_res']} ({r['ratio_res_count']})"
                    f" | C: {r['spout_num_cap']} vs {r['magic_num_cap']} ({r['ratio_cap_count']})"
                )

    # Summary table — element counts
    print()
    print("=" * 95)
    print("ELEMENT COUNTS")
    print(f"{'Circuit':<28} {'Spout R':>8} {'Magic R':>8} {'Ratio':>10}"
          f"  {'Spout C':>8} {'Magic C':>8} {'Ratio':>10}")
    print("-" * 95)

    for r in results:
        if "error" in r:
            print(f"{r['circuit']:<28} ERROR: {r['error']}")
            continue
        print(f"{r['circuit']:<28} {r['spout_num_res']:>8} {r['magic_num_res']:>8} {r['ratio_res_count']:>10}"
              f"  {r['spout_num_cap']:>8} {r['magic_num_cap']:>8} {r['ratio_cap_count']:>10}")

    # Summary table — total values
    print()
    print("TOTAL VALUES")
    print(f"{'Circuit':<28} {'Spout R':>10} {'Magic R':>10} {'Ratio':>10}"
          f"  {'Spout C':>10} {'Magic C':>10} {'Ratio':>10}")
    print(f"{'':28} {'(Ohm)':>10} {'(Ohm)':>10} {'':>10}"
          f"  {'(fF)':>10} {'(fF)':>10} {'':>10}")
    print("-" * 95)

    for r in results:
        if "error" in r:
            continue
        print(f"{r['circuit']:<28} {r['spout_total_res']:>10.3f} {r['magic_total_res']:>10.3f} {r['ratio_res_ohm']:>10}"
              f"  {r['spout_total_cap']:>10.3f} {r['magic_total_cap']:>10.3f} {r['ratio_cap_ff']:>10}")

    # Per-net detail (verbose mode)
    if args.verbose:
        for r in results:
            if "error" in r:
                continue
            if r.get("magic_net_caps"):
                print(f"\n  Per-net cap breakdown (MAGIC): {r['circuit']}")
                print(f"  {'Net':<30} {'Cap (fF)':>12}")
                print(f"  {'-'*42}")
                for net, cap in sorted(r["magic_net_caps"].items(),
                                       key=lambda x: -x[1])[:10]:
                    print(f"  {net:<30} {cap:>12.4f}")

    # Final score
    valid = [r for r in results if "error" not in r]
    count_matches = sum(
        1 for r in valid
        if "MATCH" in r["ratio_cap_count"]
        and ("MATCH" in r["ratio_res_count"] or r["magic_num_res"] == 0)
    )
    print()
    print("-" * 95)
    print(f"  {count_matches}/{len(valid)} circuits with count match (within 5%)")

    total_delta_r = sum(abs(r["delta_res_count"]) for r in valid)
    total_delta_c = sum(abs(r["delta_cap_count"]) for r in valid)
    print(f"  Total absolute delta: R={total_delta_r}, C={total_delta_c}")

    sys.exit(0 if count_matches == len(valid) else 1)


if __name__ == "__main__":
    main()
