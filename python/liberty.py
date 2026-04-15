#!/usr/bin/env python3
"""Liberty file production CLI for Spout.

Usage:
    python -m python.liberty generate cell.gds cell.spice --cell-name my_cell --pdk sky130
    python -m python.liberty generate cell.gds cell.spice --cell-name my_cell --all-corners --output-dir ./lib/
"""

from __future__ import annotations

import argparse
import ctypes
import os
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Optional


# ---------------------------------------------------------------------------
# Result types
# ---------------------------------------------------------------------------


@dataclass
class LibertyResult:
    output_path: str
    corner: str


@dataclass
class LibertyAllCornersResult:
    num_files: int
    output_dir: str


# ---------------------------------------------------------------------------
# Shared library discovery
# ---------------------------------------------------------------------------


def _get_lib_path() -> Path:
    """Find libspout.so relative to this file or in standard locations."""
    candidates = [
        Path(__file__).parent / "libspout.so",
        Path(__file__).parent.parent / "libspout.so",
        Path("/usr/local/lib/libspout.so"),
    ]
    for p in candidates:
        if p.exists():
            return p
    raise FileNotFoundError(
        "libspout.so not found. Run 'zig build' first."
    )


# ---------------------------------------------------------------------------
# PDK name → integer ID mapping
# Must match the order in src/lib.zig (spout_init_layout) and
# src/liberty/pdk.zig (PdkId enum: sky130=0, gf180mcu=1).
# The CLI exposes "gf180" as a shorthand for gf180mcu.
# ---------------------------------------------------------------------------

_PDK_IDS: dict[str, int] = {
    "sky130": 0,
    "gf180": 1,
    "gf180mcu": 1,
    "ihp130": 2,
}


# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------


def cmd_generate(args: argparse.Namespace) -> int:
    """Generate Liberty file for one corner or all corners."""
    gds_path = Path(args.gds)
    spice_path = Path(args.spice)

    if not gds_path.exists():
        print(f"Error: GDS file not found: {gds_path}", file=sys.stderr)
        return 1
    if not spice_path.exists():
        print(f"Error: SPICE file not found: {spice_path}", file=sys.stderr)
        return 1

    # Check ngspice is available.
    import shutil
    if shutil.which("ngspice") is None:
        print(
            "Error: ngspice not found in PATH. Install ngspice first.",
            file=sys.stderr,
        )
        return 1

    try:
        lib_path = _get_lib_path()
    except FileNotFoundError as exc:
        print(f"Error: {exc}", file=sys.stderr)
        return 1

    try:
        lib = ctypes.CDLL(str(lib_path))
    except OSError as exc:
        print(f"Error: could not load {lib_path}: {exc}", file=sys.stderr)
        return 1

    pdk_id = _PDK_IDS.get(args.pdk, 0)

    if args.all_corners:
        output_dir = args.output_dir or "."
        os.makedirs(output_dir, exist_ok=True)

        lib.spout_liberty_generate_all_corners.restype = ctypes.c_int
        lib.spout_liberty_generate_all_corners.argtypes = [
            ctypes.c_char_p,                  # gds_path
            ctypes.c_char_p,                  # spice_path
            ctypes.c_char_p,                  # cell_name
            ctypes.c_int,                     # pdk_id
            ctypes.c_char_p,                  # output_dir
            ctypes.POINTER(ctypes.c_uint32),  # out_num_files
        ]

        num_files = ctypes.c_uint32(0)
        ret = lib.spout_liberty_generate_all_corners(
            str(gds_path).encode(),
            str(spice_path).encode(),
            args.cell_name.encode(),
            pdk_id,
            output_dir.encode(),
            ctypes.byref(num_files),
        )
        if ret != 0:
            print(
                f"Error: Liberty generation failed (code {ret})",
                file=sys.stderr,
            )
            return 1

        n = num_files.value
        print(f"Generated {n} Liberty files in {output_dir}/")
        lib_files = sorted(Path(output_dir).glob(f"{args.cell_name}_*.lib"))
        for f in lib_files:
            print(f"  {f}")

    else:
        corner = args.corner or "tt_025C_1v80"
        output = args.output or f"{args.cell_name}_{corner}.lib"

        lib.spout_liberty_generate.restype = ctypes.c_int
        lib.spout_liberty_generate.argtypes = [
            ctypes.c_char_p,  # gds_path
            ctypes.c_char_p,  # spice_path
            ctypes.c_char_p,  # cell_name
            ctypes.c_int,     # pdk_id
            ctypes.c_char_p,  # corner_name
            ctypes.c_char_p,  # output_path
        ]

        ret = lib.spout_liberty_generate(
            str(gds_path).encode(),
            str(spice_path).encode(),
            args.cell_name.encode(),
            pdk_id,
            corner.encode(),
            output.encode(),
        )
        if ret != 0:
            print(
                f"Error: Liberty generation failed (code {ret})",
                file=sys.stderr,
            )
            return 1

        print(f"Generated: {output}")

    return 0


# ---------------------------------------------------------------------------
# Argument parser
# ---------------------------------------------------------------------------


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Spout Liberty file generator",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  # Single corner (default tt_025C_1v80)
  python -m python.liberty generate cell.gds cell.spice --cell-name inv_cs

  # All PVT corners
  python -m python.liberty generate cell.gds cell.spice --cell-name inv_cs --all-corners --output-dir ./lib/

  # Specific corner
  python -m python.liberty generate cell.gds cell.spice --cell-name inv_cs --corner ss_100C_1v60

  # Custom output path
  python -m python.liberty generate cell.gds cell.spice --cell-name inv_cs -o my_inv_tt.lib
        """,
    )

    subparsers = parser.add_subparsers(dest="command", required=True)

    gen = subparsers.add_parser("generate", help="Generate Liberty file(s)")
    gen.add_argument("gds", help="Input GDS file path")
    gen.add_argument("spice", help="Input SPICE netlist path")
    gen.add_argument(
        "--cell-name", "-c",
        required=True,
        help="Cell name (must match .subckt name in the SPICE netlist)",
    )
    gen.add_argument(
        "--pdk",
        default="sky130",
        choices=["sky130", "gf180", "gf180mcu", "ihp130"],
        help="Target PDK (default: sky130)",
    )
    gen.add_argument(
        "--corner",
        default=None,
        help="Corner name, e.g. tt_025C_1v80 (default). Ignored with --all-corners.",
    )
    gen.add_argument(
        "--all-corners", "-a",
        action="store_true",
        help="Generate Liberty files for all PVT corners of the PDK",
    )
    gen.add_argument(
        "--output", "-o",
        default=None,
        help="Output .lib file path (default: {cell_name}_{corner}.lib)",
    )
    gen.add_argument(
        "--output-dir",
        default=None,
        help="Output directory for --all-corners mode (default: current directory)",
    )
    gen.set_defaults(func=cmd_generate)

    args = parser.parse_args()
    sys.exit(args.func(args))


if __name__ == "__main__":
    main()
