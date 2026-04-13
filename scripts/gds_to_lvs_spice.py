#!/usr/bin/env python3
"""Convert a GDS file to an LVS-ready SPICE netlist via MAGIC extraction.

MAGIC reads the GDS, performs extraction, and writes a SPICE netlist with
device models and net connectivity — exactly what NETGEN needs for LVS.

Usage:
    nix develop --command python scripts/gds_to_lvs_spice.py circuit.gds -o layout.spice
    nix develop --command python scripts/gds_to_lvs_spice.py circuit.gds --top-cell current_mirror

Requires: magic binary on PATH, PDK_ROOT set with SKY130 installed.
"""
from __future__ import annotations

import os
import pathlib
import shutil
import subprocess
import sys
import tempfile


def gds_to_lvs_spice(
    gds_path: pathlib.Path,
    top_cell: str,
    output_path: pathlib.Path | None = None,
    pdk: str = "sky130",
    work_dir: pathlib.Path | None = None,
) -> pathlib.Path:
    """Extract an LVS SPICE netlist from a GDS file using MAGIC.

    Parameters
    ----------
    gds_path : Path
        Input GDS file.
    top_cell : str
        Top cell name in the GDS.
    output_path : Path or None
        Where to write the output SPICE.  Defaults to <gds_stem>_extracted.spice
        next to the GDS file.
    pdk : str
        PDK name ("sky130", "gf180", "ihp130").
    work_dir : Path or None
        Working directory for MAGIC.  Uses a temp dir if None.

    Returns
    -------
    Path
        Path to the extracted SPICE file.

    Raises
    ------
    RuntimeError
        If MAGIC is not available, PDK_ROOT is not set, or extraction fails.
    FileNotFoundError
        If the GDS file doesn't exist.
    """
    if not gds_path.exists():
        raise FileNotFoundError(f"GDS file not found: {gds_path}")

    if not shutil.which("magic"):
        raise RuntimeError("magic binary not found on PATH")

    pdk_root = os.environ.get("PDK_ROOT")
    if not pdk_root:
        raise RuntimeError("PDK_ROOT environment variable not set")

    # Resolve tech file path
    pdk_variants = {"sky130": "sky130A", "gf180": "gf180mcuD", "ihp130": "ihp-sg13g2"}
    variant = pdk_variants.get(pdk)
    if not variant:
        raise ValueError(f"Unknown PDK: {pdk}")

    tech_file = pathlib.Path(pdk_root) / variant / "libs.tech" / "magic" / f"{variant}.tech"
    if not tech_file.exists():
        raise RuntimeError(f"Tech file not found: {tech_file}")

    if output_path is None:
        output_path = gds_path.with_name(f"{gds_path.stem}_extracted.spice")

    # MAGIC writes intermediate .ext files into CWD, so use a work directory.
    cleanup_work = work_dir is None
    if work_dir is None:
        work_dir = pathlib.Path(tempfile.mkdtemp(prefix="spout_magic_"))

    try:
        tcl_script = f"""\
tech load {tech_file}
gds read {gds_path.resolve()}
load {top_cell}
select top cell
extract all
ext2spice lvs
ext2spice format ngspice
ext2spice -o {output_path.resolve()}
ext2spice
puts "EXTRACTION_DONE"
quit
"""
        result = subprocess.run(
            ["magic", "-dnull", "-noconsole"],
            input=tcl_script,
            capture_output=True,
            text=True,
            timeout=120,
            cwd=str(work_dir),
        )

        if "EXTRACTION_DONE" not in result.stdout:
            # Check if output was still produced despite missing marker
            if not output_path.exists():
                raise RuntimeError(
                    f"MAGIC extraction failed (rc={result.returncode}).\n"
                    f"stdout: {result.stdout[-500:]}\n"
                    f"stderr: {result.stderr[-500:]}"
                )

        # If ext2spice -o didn't work, try the default output location
        if not output_path.exists():
            default_spice = work_dir / f"{top_cell}.spice"
            if default_spice.exists():
                shutil.copy2(default_spice, output_path)
            else:
                # Try lowercase
                default_spice = work_dir / f"{top_cell.lower()}.spice"
                if default_spice.exists():
                    shutil.copy2(default_spice, output_path)
                else:
                    # Last resort: any .spice file
                    candidates = sorted(work_dir.glob("*.spice"))
                    if candidates:
                        shutil.copy2(candidates[0], output_path)
                    else:
                        raise RuntimeError(
                            "MAGIC did not produce a .spice file.\n"
                            f"stdout: {result.stdout[-500:]}"
                        )

        if not output_path.exists():
            raise RuntimeError("Failed to produce output SPICE file")

        return output_path

    finally:
        if cleanup_work and work_dir.exists():
            shutil.rmtree(work_dir, ignore_errors=True)


def main() -> None:
    import argparse

    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("gds", type=pathlib.Path, help="Input GDS file")
    ap.add_argument("-o", "--output", type=pathlib.Path, default=None,
                    help="Output SPICE file (default: <gds>_extracted.spice)")
    ap.add_argument("--top-cell", default=None,
                    help="Top cell name (default: derived from filename)")
    ap.add_argument("--pdk", default="sky130", choices=["sky130", "gf180", "ihp130"])
    args = ap.parse_args()

    top_cell = args.top_cell or args.gds.stem
    out = gds_to_lvs_spice(args.gds, top_cell, args.output, args.pdk)
    print(f"Extracted: {out}")


if __name__ == "__main__":
    main()
