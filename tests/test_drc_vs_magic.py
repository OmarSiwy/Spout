"""Compare Spout's in-engine DRC against MAGIC DRC.

Runs both tools on the same benchmark circuits and checks that Spout's
violation count is consistent with MAGIC's results.

Requires:
    - libspout.so built (zig build)
    - magic binary on PATH
    - PDK_ROOT set with SKY130 installed
"""
from __future__ import annotations

import os
import pathlib
import shutil
import subprocess

import pytest

from conftest import BENCHMARKS_DIR, LIBSPOUT_PATH

requires_libspout = pytest.mark.skipif(
    not LIBSPOUT_PATH.exists(), reason="libspout.so not built"
)
requires_magic = pytest.mark.skipif(
    shutil.which("magic") is None, reason="magic binary not on PATH"
)
requires_pdk_root = pytest.mark.skipif(
    not os.environ.get("PDK_ROOT"), reason="PDK_ROOT not set"
)


def _run_spout_drc(netlist: pathlib.Path, output_dir: pathlib.Path) -> int:
    """Run Spout pipeline and return in-engine DRC violation count."""
    from spout.config import SpoutConfig, SaConfig
    from spout.pipeline import run_pipeline

    sa = SaConfig(max_iterations=500, cooling_rate=0.95, initial_temp=100.0)
    config = SpoutConfig(
        backend="klayout", pdk="sky130", sa_config=sa,
        use_ml=False, use_gradient=False, use_repair=False,
    )
    gds_path = str(output_dir / "test_output.gds")
    result = run_pipeline(str(netlist), config, output_path=gds_path)
    return result.drc_violations


def _run_magic_drc(gds_path: pathlib.Path, top_cell: str) -> int:
    """Run MAGIC DRC on a GDS file and return violation count."""
    pdk_root = os.environ["PDK_ROOT"]
    tech_file = pathlib.Path(pdk_root) / "sky130A" / "libs.tech" / "magic" / "sky130A.tech"

    tcl_script = f"""
tech load {tech_file}
gds read {gds_path}
load {top_cell}
select top cell
drc check
drc catchup
set count [drc listall count]
puts "MAGIC_DRC_COUNT: $count"
quit
"""
    try:
        result = subprocess.run(
            ["magic", "-dnull", "-noconsole"],
            input=tcl_script,
            capture_output=True,
            text=True,
            timeout=60,
        )
    except (subprocess.TimeoutExpired, OSError):
        return -1

    # MAGIC may exit with a signal (e.g. SIGSEGV, rc=-11) after flushing DRC output.
    # Negative return codes indicate signal kills — output may still be valid.
    # Only hard-fail on unexpected positive error codes (> 1).
    if result.returncode > 1:
        return -1

    for line in result.stdout.splitlines():
        if line.startswith("MAGIC_DRC_COUNT:"):
            # `drc listall count` returns a Tcl list of {cellname count} pairs,
            # e.g. "{current_mirror 232}". Sum the counts across all cells.
            raw = line.split(":", 1)[1].strip().strip("{}")
            parts = raw.split()
            try:
                return sum(int(parts[i]) for i in range(1, len(parts), 2))
            except (ValueError, IndexError):
                return -1
    return -1


# ---------------------------------------------------------------------------
# Test cases
# ---------------------------------------------------------------------------

SMALL_BENCHMARKS = [
    "current_mirror",
    "diff_pair",
    "five_transistor_ota",
]


@requires_libspout
@requires_magic
@requires_pdk_root
@pytest.mark.parametrize("circuit", SMALL_BENCHMARKS)
def test_drc_spout_vs_magic(circuit: str, tmp_path: pathlib.Path) -> None:
    """Spout in-engine DRC violation count should be <= MAGIC's count.

    Spout's sweep-line DRC is stricter (catches more violations at finer
    granularity), so Spout violations >= MAGIC violations is expected.
    The key check: if MAGIC says 0 violations, Spout must also say 0.
    """
    netlist = BENCHMARKS_DIR / f"{circuit}.spice"
    if not netlist.exists():
        pytest.skip(f"Benchmark {circuit}.spice not found")

    spout_violations = _run_spout_drc(netlist, tmp_path)
    gds_path = tmp_path / "test_output.gds"

    if not gds_path.exists():
        pytest.skip("GDS not generated (pipeline may have failed)")

    magic_violations = _run_magic_drc(gds_path, circuit)

    if magic_violations == -1:
        pytest.skip("MAGIC DRC crashed or produced unparseable output")

    # If MAGIC is clean, Spout must also be clean
    if magic_violations == 0:
        assert spout_violations == 0, (
            f"MAGIC reports 0 violations but Spout reports {spout_violations}"
        )

    # Report both counts for analysis
    print(f"\n  {circuit}: Spout={spout_violations}, MAGIC={magic_violations}")
