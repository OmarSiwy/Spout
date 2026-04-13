#!/usr/bin/env python3
"""Compare Spout vs MAGIC PEX values (total fF, total Ω, per-element).

Runs both extractors on benchmark circuits and prints a side-by-side table
of actual parasitic values, not just element counts.
"""
from __future__ import annotations

import os
import pathlib
import shutil
import subprocess
import sys
import tempfile
import re

# ── paths ──────────────────────────────────────────────────────────────────
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
BENCHMARKS = ROOT / "fixtures" / "benchmark"

CIRCUITS = [
    "current_mirror",
    "diff_pair",
    "five_transistor_ota",
    "folded_cascode",
    "sar_adc_comparator",
]


def run_spout(netlist: pathlib.Path, tmp: pathlib.Path) -> dict:
    from spout.config import SpoutConfig, SaConfig
    from spout.pipeline import run_pipeline

    sa = SaConfig(max_iterations=500, cooling_rate=0.95, initial_temp=100.0)
    cfg = SpoutConfig(
        backend="klayout", pdk="sky130", sa_config=sa,
        use_ml=False, use_gradient=False, use_repair=False,
    )
    gds = str(tmp / "out.gds")
    result = run_pipeline(str(netlist), cfg, output_path=gds)
    pex = result.pex_assessment
    return {
        "num_res": result.pex_parasitic_res,
        "num_cap": result.pex_parasitic_caps,
        "total_cap_ff": pex.total_cap_ff if pex else 0.0,
        "total_res_ohm": pex.total_res_ohm if pex else 0.0,
        "gds": gds,
    }


def parse_magic_spice(spice_path: pathlib.Path) -> dict:
    """Parse MAGIC ext2spice SPICE output for R/C values."""
    res_values = []
    cap_values = []
    for line in spice_path.read_text(errors="replace").splitlines():
        s = line.strip()
        if not s or s.startswith("*") or s.startswith("."):
            continue
        parts = s.split()
        first = parts[0][0].upper()
        if first == "R" and len(parts) >= 4:
            try:
                res_values.append(_parse_spice_value(parts[3]))
            except (ValueError, IndexError):
                pass
        elif first == "C" and len(parts) >= 4:
            try:
                cap_values.append(_parse_spice_value(parts[3]))
            except (ValueError, IndexError):
                pass
    total_r = sum(res_values)
    total_c_ff = sum(cap_values) * 1e15  # SPICE values in F → fF
    return {
        "num_res": len(res_values),
        "num_cap": len(cap_values),
        "total_res_ohm": total_r,
        "total_cap_ff": total_c_ff,
        "res_values": res_values,
        "cap_values_ff": [v * 1e15 for v in cap_values],
    }


def _parse_spice_value(s: str) -> float:
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


def run_magic(gds_path: str, circuit: str, tmp: pathlib.Path) -> dict | None:
    if not shutil.which("magic"):
        return None
    pdk_root = os.environ.get("PDK_ROOT")
    if not pdk_root:
        return None

    tech = pathlib.Path(pdk_root) / "sky130A" / "libs.tech" / "magic" / "sky130A.tech"
    tcl = f"""
tech load {tech}
gds read {gds_path}
load {circuit}
select top cell
extract all
ext2spice hierarchy on
ext2spice format ngspice
ext2spice resistance on
ext2spice cthresh 0
ext2spice rthresh 0
ext2spice
puts "EXT2SPICE_DONE"
quit
"""
    try:
        result = subprocess.run(
            ["magic", "-dnull", "-noconsole"],
            input=tcl, capture_output=True, text=True, timeout=120, cwd=str(tmp),
        )
    except (subprocess.TimeoutExpired, OSError):
        return None
    if "EXT2SPICE_DONE" not in result.stdout:
        return None

    for name in [f"{circuit}.spice", f"{circuit.lower()}.spice"]:
        sp = tmp / name
        if sp.exists():
            return parse_magic_spice(sp)
    candidates = sorted(tmp.glob("*.spice"))
    if candidates:
        return parse_magic_spice(candidates[0])
    return None


def ratio_str(a: float, b: float) -> str:
    if b == 0 and a == 0:
        return "—"
    if b == 0:
        return "∞"
    r = a / b
    tag = ""
    if r > 1.05:
        tag = " OVER"
    elif r < 1.0 / 1.05:
        tag = " UNDER"
    else:
        tag = " ✓"
    return f"{r:.3f}x{tag}"


def main():
    print("=" * 90)
    print("PEX VALUE COMPARISON: Spout vs MAGIC")
    print("=" * 90)

    for circuit in CIRCUITS:
        netlist = BENCHMARKS / f"{circuit}.spice"
        if not netlist.exists():
            print(f"\n{circuit}: SKIP (netlist not found)")
            continue

        with tempfile.TemporaryDirectory() as tmp_str:
            tmp = pathlib.Path(tmp_str)
            print(f"\n{'─' * 90}")
            print(f"  {circuit}")
            print(f"{'─' * 90}")

            spout = run_spout(netlist, tmp)
            magic = run_magic(spout["gds"], circuit, tmp)

            print(f"  {'':30s} {'Spout':>15s}  {'MAGIC':>15s}  {'Ratio':>15s}")
            print(f"  {'Num R elements':30s} {spout['num_res']:>15d}", end="")
            if magic:
                print(f"  {magic['num_res']:>15d}  {ratio_str(spout['num_res'], magic['num_res']):>15s}")
            else:
                print(f"  {'N/A':>15s}")

            print(f"  {'Num C elements':30s} {spout['num_cap']:>15d}", end="")
            if magic:
                print(f"  {magic['num_cap']:>15d}  {ratio_str(spout['num_cap'], magic['num_cap']):>15s}")
            else:
                print(f"  {'N/A':>15s}")

            print(f"  {'Total R (Ω)':30s} {spout['total_res_ohm']:>15.3f}", end="")
            if magic:
                print(f"  {magic['total_res_ohm']:>15.3f}  {ratio_str(spout['total_res_ohm'], magic['total_res_ohm']):>15s}")
            else:
                print(f"  {'N/A':>15s}")

            print(f"  {'Total C (fF)':30s} {spout['total_cap_ff']:>15.3f}", end="")
            if magic:
                print(f"  {magic['total_cap_ff']:>15.3f}  {ratio_str(spout['total_cap_ff'], magic['total_cap_ff']):>15s}")
            else:
                print(f"  {'N/A':>15s}")

            if magic and magic.get("cap_values_ff"):
                caps = sorted(magic["cap_values_ff"], reverse=True)
                print(f"\n  MAGIC top-5 C values (fF): {', '.join(f'{c:.4f}' for c in caps[:5])}")
            if magic and magic.get("res_values"):
                res = sorted(magic["res_values"], reverse=True)
                print(f"  MAGIC top-5 R values (Ω):  {', '.join(f'{r:.3f}' for r in res[:5])}")

    print(f"\n{'=' * 90}")


if __name__ == "__main__":
    main()
