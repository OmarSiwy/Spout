#!/usr/bin/env python3
"""Compare Spout's in-engine ext2spice against MAGIC's ext2spice for equivalence.

Goal: Both ext2spice implementations should produce SPICE netlists that NETGEN
accepts as matching the schematic.  This tests that Spout's own ext2spice
correctly represents the circuit topology.

Flow per circuit:
  1. Spout pipeline → route + export GDS
  2. Spout ext2spice → layout SPICE (via FFI, uses parsed model names)
  3. MAGIC ext2spice → layout SPICE (from GDS)
  4. Run NETGEN on each layout SPICE vs schematic SPICE
  5. Compare verdicts: both should say MATCH

Usage:
    nix develop .#test --command python scripts/compare_lvs.py
    nix develop .#test --command python scripts/compare_lvs.py -c current_mirror
    nix develop .#test --command python scripts/compare_lvs.py --all
"""
from __future__ import annotations

import argparse
import os
import pathlib
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
# Spout pipeline
# ---------------------------------------------------------------------------

def run_spout_pipeline(netlist: pathlib.Path, output_dir: pathlib.Path) -> dict:
    """Run Spout pipeline and return handle + metadata."""
    from spout.config import SaConfig
    from spout.ffi import SpoutFFI

    ffi = SpoutFFI()
    handle = ffi.init_layout(backend=1, pdk=0)  # klayout, sky130

    sa = SaConfig(max_iterations=500, cooling_rate=0.95, initial_temp=100.0)
    config_json = sa.to_ffi_bytes()

    ffi.parse_netlist(handle, str(netlist))
    ffi.extract_constraints(handle)
    ffi.run_sa_placement(handle, config_json)
    ffi.run_routing(handle)

    # Export GDS for MAGIC-based extraction
    top_cell = ""
    with open(netlist) as f:
        for line in f:
            if line.strip().lower().startswith(".subckt"):
                top_cell = line.strip().split()[1]

    gds_path = output_dir / "test_output.gds"
    ffi.export_gdsii(handle, str(gds_path), top_cell)

    return {
        "ffi": ffi,
        "handle": handle,
        "gds_path": gds_path,
        "top_cell": top_cell,
    }


def cleanup_spout(spout_data: dict) -> None:
    """Destroy the FFI handle."""
    try:
        spout_data["ffi"].destroy(spout_data["handle"])
    except Exception:
        pass


# ---------------------------------------------------------------------------
# Spout ext2spice (in-engine)
# ---------------------------------------------------------------------------

def generate_spout_ext2spice(
    spout_data: dict,
    output_path: pathlib.Path,
) -> pathlib.Path | None:
    """Generate layout SPICE using Spout's in-engine ext2spice."""
    try:
        spout_data["ffi"].ext2spice(spout_data["handle"], str(output_path))
        if output_path.exists() and output_path.stat().st_size > 0:
            return output_path
        return None
    except Exception as exc:
        print(f"\n    WARNING: Spout ext2spice failed: {exc}")
        return None


# ---------------------------------------------------------------------------
# MAGIC ext2spice (GDS extraction)
# ---------------------------------------------------------------------------

def generate_magic_ext2spice(
    gds_path: pathlib.Path,
    top_cell: str,
    output_path: pathlib.Path,
    work_dir: pathlib.Path,
) -> pathlib.Path | None:
    """Extract layout SPICE from GDS using MAGIC."""
    pdk_root = os.environ.get("PDK_ROOT")
    if not pdk_root or not shutil.which("magic"):
        return None

    tech_file = (
        pathlib.Path(pdk_root) / "sky130A" / "libs.tech" / "magic" / "sky130A.tech"
    )

    tcl_script = f"""\
tech load {tech_file}
gds read {gds_path}
load {top_cell}
select top cell
extract all
ext2spice lvs
ext2spice format ngspice
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
    except (subprocess.TimeoutExpired, OSError):
        return None

    if "EXT2SPICE_DONE" not in result.stdout:
        return None

    # Find the output SPICE file
    for name in [f"{top_cell}.spice", f"{top_cell.lower()}.spice"]:
        sp = work_dir / name
        if sp.exists():
            shutil.copy2(sp, output_path)
            return output_path

    candidates = sorted(work_dir.glob("*.spice"))
    if candidates:
        shutil.copy2(candidates[0], output_path)
        return output_path

    return None


# ---------------------------------------------------------------------------
# NETGEN LVS
# ---------------------------------------------------------------------------

def run_netgen_lvs(
    layout_spice: pathlib.Path,
    schematic_spice: pathlib.Path,
    top_cell: str,
    work_dir: pathlib.Path,
) -> dict:
    """Run NETGEN batch LVS and return match result + details."""
    pdk_root = os.environ.get("PDK_ROOT")
    if not pdk_root:
        return {"error": "PDK_ROOT not set"}
    if not shutil.which("netgen"):
        return {"error": "netgen not on PATH"}

    setup_tcl = (
        pathlib.Path(pdk_root) / "sky130A"
        / "libs.tech" / "netgen" / "sky130A_setup.tcl"
    )
    out_file = work_dir / "lvs_output.txt"

    env = os.environ.copy()
    env["DISPLAY"] = ""  # headless

    try:
        result = subprocess.run(
            [
                "netgen", "-batch", "lvs",
                f"{layout_spice} {top_cell}",
                f"{schematic_spice} {top_cell}",
                str(setup_tcl),
                str(out_file),
            ],
            capture_output=True,
            text=True,
            timeout=120,
            cwd=str(work_dir),
            env=env,
        )
    except (subprocess.TimeoutExpired, OSError) as exc:
        return {"error": f"netgen failed: {exc}"}

    combined = result.stdout + result.stderr
    if out_file.exists():
        combined += out_file.read_text(errors="replace")

    match = "Circuits match uniquely." in combined or "Circuits match" in combined

    # Extract mismatch details
    device_mismatches = []
    net_mismatches = []
    for line in combined.splitlines():
        if "missing" in line.lower() or "mismatch" in line.lower():
            if "device" in line.lower():
                device_mismatches.append(line.strip())
            elif "net" in line.lower():
                net_mismatches.append(line.strip())

    return {
        "match": match,
        "device_mismatches": device_mismatches,
        "net_mismatches": net_mismatches,
        "output": combined[-2000:],
    }


# ---------------------------------------------------------------------------
# Comparison
# ---------------------------------------------------------------------------

def compare_circuit(circuit: str, work_dir: pathlib.Path, verbose: bool = False) -> dict:
    """Compare Spout ext2spice vs MAGIC ext2spice for one circuit."""
    # Use _lvs.spice variant if available (has SKY130 model names for NETGEN)
    schematic_lvs = BENCHMARKS_DIR / f"{circuit}_lvs.spice"
    if not schematic_lvs.exists():
        schematic_lvs = BENCHMARKS_DIR / f"{circuit}.spice"
    if not schematic_lvs.exists():
        return {"circuit": circuit, "error": "netlist not found"}

    # Run Spout pipeline
    spout_data = run_spout_pipeline(schematic_lvs, work_dir)
    top_cell = spout_data["top_cell"]
    if not top_cell:
        cleanup_spout(spout_data)
        return {"circuit": circuit, "error": "no .subckt found"}

    try:
        # Path A: Spout in-engine ext2spice
        spout_spice = work_dir / "layout_spout.spice"
        spout_ok = generate_spout_ext2spice(spout_data, spout_spice)

        # Path B: MAGIC ext2spice from GDS
        magic_work = work_dir / "magic_work"
        magic_work.mkdir(exist_ok=True)
        magic_spice = work_dir / "layout_magic.spice"
        magic_ok = generate_magic_ext2spice(
            spout_data["gds_path"], top_cell, magic_spice, magic_work,
        )

        # Run NETGEN on Spout ext2spice output
        netgen_spout = None
        if spout_ok:
            spout_netgen_work = work_dir / "netgen_spout"
            spout_netgen_work.mkdir(exist_ok=True)
            netgen_spout = run_netgen_lvs(
                spout_spice, schematic_lvs, top_cell, spout_netgen_work,
            )

        # Run NETGEN on MAGIC ext2spice output
        netgen_magic = None
        if magic_ok:
            magic_netgen_work = work_dir / "netgen_magic"
            magic_netgen_work.mkdir(exist_ok=True)
            netgen_magic = run_netgen_lvs(
                magic_spice, schematic_lvs, top_cell, magic_netgen_work,
            )

        # Build result
        result: dict = {"circuit": circuit}

        # Spout ext2spice → NETGEN verdict
        if netgen_spout and "error" not in netgen_spout:
            result["spout_match"] = netgen_spout["match"]
            result["spout_details"] = netgen_spout
        else:
            result["spout_match"] = None
            result["spout_error"] = (
                netgen_spout.get("error", "ext2spice failed")
                if netgen_spout else "ext2spice failed"
            )

        # MAGIC ext2spice → NETGEN verdict
        if netgen_magic and "error" not in netgen_magic:
            result["magic_match"] = netgen_magic["match"]
            result["magic_details"] = netgen_magic
        else:
            result["magic_match"] = None
            result["magic_error"] = (
                netgen_magic.get("error", "magic ext2spice failed")
                if netgen_magic else "magic ext2spice failed"
            )

        # Agreement: do both paths agree?
        if result.get("spout_match") is not None and result.get("magic_match") is not None:
            result["agree"] = result["spout_match"] == result["magic_match"]
        else:
            result["agree"] = None

        if verbose:
            # Dump SPICE files for debugging
            for tag, sp in [("spout", spout_spice), ("magic", magic_spice)]:
                if sp.exists():
                    print(f"\n    [{tag} SPICE] {sp}")
                    content = sp.read_text()
                    for line in content.splitlines()[:20]:
                        print(f"      {line}")

        return result

    finally:
        cleanup_spout(spout_data)


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main() -> None:
    ap = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    ap.add_argument("-c", "--circuits", nargs="+", metavar="NAME")
    ap.add_argument("--all", action="store_true")
    ap.add_argument("--verbose", "-v", action="store_true")
    args = ap.parse_args()

    if args.all:
        circuits = sorted(
            p.stem for p in BENCHMARKS_DIR.glob("*.spice")
            if "_lvs" not in p.stem and "_pex" not in p.stem
        )
    else:
        circuits = args.circuits or DEFAULT_CIRCUITS

    print("=" * 100)
    print("LVS EXT2SPICE COMPARISON: Spout ext2spice vs MAGIC ext2spice (via NETGEN)")
    print("=" * 100)
    print("Goal: Both ext2spice implementations should produce NETGEN-matching SPICE")
    print()

    results = []
    for circuit in circuits:
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = pathlib.Path(tmp)
            print(f"  {circuit} ...", end="", flush=True)
            r = compare_circuit(circuit, tmp_path, verbose=args.verbose)
            results.append(r)

            if "error" in r:
                print(f"  ERROR: {r['error']}")
            else:
                spout_str = "N/A"
                if r.get("spout_match") is not None:
                    spout_str = "MATCH" if r["spout_match"] else "MISMATCH"
                elif r.get("spout_error"):
                    spout_str = "ERR"

                magic_str = "N/A"
                if r.get("magic_match") is not None:
                    magic_str = "MATCH" if r["magic_match"] else "MISMATCH"
                elif r.get("magic_error"):
                    magic_str = "ERR"

                agree_str = ""
                if r.get("agree") is True:
                    agree_str = " [AGREE]"
                elif r.get("agree") is False:
                    agree_str = " [DISAGREE]"

                print(f"  Spout={spout_str} | MAGIC={magic_str}{agree_str}")

    # Summary table
    print()
    print("=" * 100)
    print(f"{'Circuit':<35} {'Spout→NETGEN':<16} {'MAGIC→NETGEN':<16} {'Agree?':<10}")
    print("-" * 100)

    agreed = 0
    spout_match_count = 0
    magic_match_count = 0
    total_valid = 0

    for r in results:
        if "error" in r:
            print(f"{r['circuit']:<35} ERROR: {r['error']}")
            continue

        total_valid += 1

        spout_str = "N/A"
        if r.get("spout_match") is not None:
            spout_str = "MATCH" if r["spout_match"] else "MISMATCH"
            if r["spout_match"]:
                spout_match_count += 1

        magic_str = "N/A"
        if r.get("magic_match") is not None:
            magic_str = "MATCH" if r["magic_match"] else "MISMATCH"
            if r["magic_match"]:
                magic_match_count += 1

        agree = r.get("agree")
        agree_str = "N/A"
        if agree is True:
            agree_str = "YES"
            agreed += 1
        elif agree is False:
            agree_str = "NO"

        print(f"{r['circuit']:<35} {spout_str:<16} {magic_str:<16} {agree_str:<10}")

    print("-" * 100)
    print(f"  Spout MATCH: {spout_match_count}/{total_valid}")
    print(f"  MAGIC MATCH: {magic_match_count}/{total_valid}")
    print(f"  Agreement:   {agreed}/{total_valid}")

    sys.exit(0 if spout_match_count == total_valid and total_valid > 0 else 1)


if __name__ == "__main__":
    main()
