"""External signoff tool wrappers."""

from __future__ import annotations

import logging
import os
import subprocess
import tempfile
import xml.etree.ElementTree as ET
from pathlib import Path

logger = logging.getLogger(__name__)


def run_klayout_drc(gds_path: str, top_cell: str) -> int:
    """Run KLayout DRC on a GDS file. Returns violation count."""
    pdk_root = os.environ.get("PDK_ROOT", "")
    drc_script = Path(pdk_root) / "sky130A" / "libs.tech" / "klayout" / "drc" / "sky130A.lydrc"
    if not drc_script.exists():
        raise FileNotFoundError(f"KLayout DRC script not found: {drc_script}")
    with tempfile.TemporaryDirectory() as tmpdir:
        report_file = Path(tmpdir) / "klayout_drc_report.lyrdb"
        cmd = ["klayout", "-b", "-r", str(drc_script),
               "-rd", f"input={gds_path}", "-rd", f"topcell={top_cell}",
               "-rd", f"report={report_file}"]
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=120)
        if result.returncode != 0:
            raise RuntimeError(f"KLayout DRC failed (rc={result.returncode}): {result.stderr[:500]}")
        if not report_file.exists():
            raise RuntimeError("KLayout DRC produced no report file")
        try:
            root = ET.fromstring(report_file.read_text())
        except ET.ParseError as exc:
            raise RuntimeError(f"KLayout DRC report XML parse error: {exc}") from exc
        count = 0
        for cat in root.iter("category"):
            items_el = cat.find("items")
            if items_el is not None:
                count += len(items_el.findall("item"))
        return count


# Generic model name → sky130 KLayout-recognized name
_SKY130_MODEL_MAP = {
    "nmos_rvt": "sky130_fd_pr__nfet_01v8",
    "pmos_rvt": "sky130_fd_pr__pfet_01v8",
    "nmos_lvt": "sky130_fd_pr__nfet_01v8_lvt",
    "nmos": "sky130_fd_pr__nfet_01v8",
    "pmos": "sky130_fd_pr__pfet_01v8",
    "nfet": "sky130_fd_pr__nfet_01v8",
    "pfet": "sky130_fd_pr__pfet_01v8",
}


def _map_mosfet_model(line: str) -> str:
    stripped = line.strip()
    if not stripped or stripped.startswith("*") or stripped.startswith("."):
        return line
    if stripped[0].upper() != "M":
        return line
    tokens = stripped.split()
    if len(tokens) < 6:
        return line
    model = tokens[5].lower()
    mapped = _SKY130_MODEL_MAP.get(model)
    if not mapped:
        if model == "n":
            mapped = "sky130_fd_pr__nfet_01v8"
        elif model == "p":
            mapped = "sky130_fd_pr__pfet_01v8"
    if not mapped:
        return line
    tokens[5] = mapped
    leading = line[: len(line) - len(line.lstrip())]
    trailing = line[len(line.rstrip()):]
    return leading + " ".join(tokens) + trailing


def prepare_lvs_schematic(schematic_path: str, out_path: str) -> str:
    """Create a sky130-mapped copy of a schematic for KLayout LVS."""
    text = Path(schematic_path).read_text()
    lines = text.splitlines(keepends=True)
    mapped = [_map_mosfet_model(l) for l in lines]
    content = "".join(mapped)
    if ".global" not in content.lower():
        content = ".global vss\n" + content
    Path(out_path).write_text(content)
    return str(out_path)


def run_klayout_lvs(gds_path: str, schematic_path: str, top_cell: str) -> dict:
    """Run KLayout LVS. Returns {match: bool, details: str} or {error: str}."""
    pdk_root = os.environ.get("PDK_ROOT", "")
    for lvs_name in ("sky130.lylvs", "sky130.lvs"):
        lvs = Path(pdk_root) / "sky130A" / "libs.tech" / "klayout" / "lvs" / lvs_name
        if lvs.exists():
            break
    else:
        raise FileNotFoundError(f"KLayout LVS script not found in {pdk_root}")
    with tempfile.TemporaryDirectory() as tmpdir:
        lvs_schematic = str(Path(tmpdir) / "lvs_schematic.spice")
        prepare_lvs_schematic(os.path.abspath(schematic_path), lvs_schematic)
        report = Path(tmpdir) / "klayout_lvs_report.lyrdb"
        cmd = ["klayout", "-b", "-r", str(lvs),
               "-rd", f"input={os.path.abspath(gds_path)}",
               "-rd", f"schematic={lvs_schematic}",
               "-rd", f"topcell={top_cell}",
               "-rd", f"report={report}"]
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=180)
        combined = result.stdout + result.stderr
        if "NETLIST MATCH" in combined or "netlists match" in combined.lower():
            return {"match": True}
        if ("NETLIST MISMATCH" in combined or
                "netlists don't match" in combined.lower()):
            return {"match": False, "details": combined}
        return {"error": f"klayout LVS inconclusive (rc={result.returncode}): {combined[:500]}"}


def run_magic_pex(gds_path: str, top_cell: str, work_dir: str) -> dict:
    """Run Magic ext2spice. Returns {num_res, num_cap} or {error}."""
    pdk_root = os.environ.get("PDK_ROOT", "")
    tech_file = Path(pdk_root) / "sky130A" / "libs.tech" / "magic" / "sky130A.tech"
    if not tech_file.exists():
        raise FileNotFoundError(f"Magic tech file not found: {tech_file}")
    gds_abs = os.path.abspath(gds_path)
    work_abs = os.path.abspath(work_dir)
    tcl = f"""tech load {tech_file.resolve()}
gds read {gds_abs}
load {top_cell}
select top cell
extract do resistance
extract do capacitance
extract do coupling
extract all
ext2spice hierarchy on
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
            input=tcl, capture_output=True, text=True, timeout=120,
            cwd=work_abs, env={**os.environ, "PDK_ROOT": pdk_root},
        )
    except (subprocess.TimeoutExpired, OSError) as exc:
        return {"error": f"magic failed: {exc}"}
    if "EXT2SPICE_DONE" not in result.stdout:
        return {"error": f"ext2spice did not complete (rc={result.returncode})"}
    spice = Path(work_dir) / f"{top_cell}.spice"
    if not spice.exists():
        return {"error": f"ext2spice SPICE file not found: {spice}"}
    num_cap = num_res = 0
    for line in spice.read_text(errors="replace").splitlines():
        s = line.strip()
        if s and not s.startswith("*") and not s.startswith("."):
            if s[0].upper() == "C":
                num_cap += 1
            elif s[0].upper() == "R":
                num_res += 1
    ext_file = Path(work_dir) / f"{top_cell}.ext"
    if ext_file.exists():
        for line in ext_file.read_text(errors="replace").splitlines():
            if line.startswith("resist "):
                num_res += 1
    logger.debug("PEX top_cell=%s num_res=%d num_cap=%d", top_cell, num_res, num_cap)
    return {"num_res": num_res, "num_cap": num_cap}


# Backward-compat alias used by main.py
run_magic_ext2spice = run_magic_pex
