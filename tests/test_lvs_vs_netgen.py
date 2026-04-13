"""Compare Spout's in-engine LVS against NETGEN LVS.

Runs both tools on the same benchmark circuits and checks that Spout's
LVS match/mismatch result is consistent with NETGEN's.

Approach (Option B): generate a layout SPICE netlist from Spout's internal
device list + route connectivity, then feed that to NETGEN alongside the
schematic SPICE.  This avoids the need for MAGIC GDS→SPICE extraction.

Requires:
    - libspout.so built (zig build)
    - netgen binary on PATH
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
requires_netgen = pytest.mark.skipif(
    shutil.which("netgen") is None, reason="netgen binary not on PATH"
)
requires_pdk_root = pytest.mark.skipif(
    not os.environ.get("PDK_ROOT"), reason="PDK_ROOT not set"
)


def _run_spout_pipeline(
    netlist: pathlib.Path,
    output_dir: pathlib.Path,
) -> tuple[bool, "SpoutFFI", object]:
    """Run Spout pipeline and return (lvs_clean, ffi, handle).

    The caller MUST call ``ffi.destroy(handle)`` when done.
    """
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
    ffi.run_lvs(handle)

    lvs_clean = ffi.get_lvs_match(handle)
    return lvs_clean, ffi, handle


def _generate_layout_spice(
    schematic_path: pathlib.Path,
    ffi: "SpoutFFI",
    handle: object,
    output_path: pathlib.Path,
) -> pathlib.Path:
    """Generate layout SPICE from Spout's routed connectivity."""
    from layout_spice import generate_layout_spice

    connectivity = ffi.get_layout_connectivity(handle)
    pin_device = ffi.get_pin_device(handle)
    pin_terminal = ffi.get_pin_terminal(handle)

    return generate_layout_spice(
        schematic_path, pin_device, pin_terminal, connectivity, output_path
    )


def _run_netgen_lvs(
    layout_spice: pathlib.Path,
    schematic_spice: pathlib.Path,
    top_cell: str,
) -> tuple[bool, str]:
    """Run NETGEN LVS comparing two SPICE netlists and return (match, output)."""
    pdk_root = os.environ["PDK_ROOT"]
    setup_tcl = (
        pathlib.Path(pdk_root) / "sky130A"
        / "libs.tech" / "netgen" / "sky130A_setup.tcl"
    )

    env = os.environ.copy()
    env["DISPLAY"] = ""  # suppress GUI
    try:
        result = subprocess.run(
            [
                "netgen", "-batch", "lvs",
                f"{layout_spice} {top_cell}",
                f"{schematic_spice} {top_cell}",
                str(setup_tcl),
            ],
            capture_output=True,
            text=True,
            timeout=120,
            env=env,
        )
    except (subprocess.TimeoutExpired, OSError):
        return False, "NETGEN failed to run"

    output = result.stdout + result.stderr
    match = "Circuits match uniquely." in output
    return match, output


# ---------------------------------------------------------------------------
# Test cases
# ---------------------------------------------------------------------------

BENCHMARKS = [
    # original small set
    "current_mirror",
    "diff_pair",
    "five_transistor_ota",
    "folded_cascode",
    # ALIGN benchmark suite
    "align_adder",
    "align_cascode_current_mirror_ota",
    "align_comparator_hierarchical",
    "align_current_mirror_ota",
    "align_double_tail_sense_amplifier",
    "align_five_transistor_ota",
    "align_high_speed_comparator",
    "align_high_speed_comparator_charge_flow",
    "align_inverter_current_starved",
    "align_linear_equalizer",
    "align_mimo_bulk_beamformer",
    "align_powertrain_binary_dac",
    "align_ring_oscillator",
    "align_sc_dc_dc_converter",
    "align_single_to_diff_converter",
    "align_switched_capacitor_filter",
    "align_telescopic_ota",
    "align_telescopic_ota_with_bias",
    "align_test_vga",
    "align_unity_gain_buffers",
    "align_variable_gain_amplifier",
    "align_vco_dtype12_hierarchical",
    # larger SKY130 circuits
    "jku_sar_adc_wrapper",
    "sar_adc_comparator",
    "sky130_ring_oscillator_pex",
]


@requires_libspout
@requires_netgen
@requires_pdk_root
@pytest.mark.parametrize("circuit", BENCHMARKS)
def test_lvs_spout_vs_netgen(circuit: str, tmp_path: pathlib.Path) -> None:
    """Spout in-engine LVS should agree with NETGEN on match/mismatch.

    Both tools should agree on whether the layout matches the schematic.
    Uses layout SPICE generated from Spout's route connectivity (Option B).
    """
    # Use the _lvs.spice variant (has SKY130 model names for NETGEN).
    schematic_lvs = BENCHMARKS_DIR / f"{circuit}_lvs.spice"
    if not schematic_lvs.exists():
        # Fall back to the regular .spice if no _lvs variant exists.
        schematic_lvs = BENCHMARKS_DIR / f"{circuit}.spice"
    if not schematic_lvs.exists():
        pytest.skip(f"Benchmark {circuit} schematic not found")

    # Extract subcircuit name from the schematic.
    top_cell = ""
    with open(schematic_lvs) as f:
        for line in f:
            if line.strip().lower().startswith(".subckt"):
                top_cell = line.strip().split()[1]
    if not top_cell:
        pytest.skip(f"No .subckt found in {schematic_lvs.name}")

    # Run Spout pipeline (parse, place, route, LVS).
    spout_clean, ffi, handle = _run_spout_pipeline(schematic_lvs, tmp_path)
    try:
        # Generate layout SPICE from route connectivity.
        layout_spice = _generate_layout_spice(
            schematic_lvs, ffi, handle, tmp_path / "layout.spice"
        )
    finally:
        ffi.destroy(handle)

    # Run NETGEN comparing layout SPICE vs schematic SPICE.
    netgen_match, netgen_output = _run_netgen_lvs(
        layout_spice, schematic_lvs, top_cell
    )

    print(f"\n  {circuit}: Spout LVS={'CLEAN' if spout_clean else 'FAIL'}, "
          f"NETGEN={'MATCH' if netgen_match else 'MISMATCH'}")

    if spout_clean != netgen_match:
        # Dump NETGEN output for debugging.
        netgen_log = tmp_path / "netgen_output.txt"
        netgen_log.write_text(netgen_output)
        pytest.fail(
            f"Spout says {'clean' if spout_clean else 'mismatch'} but "
            f"NETGEN says {'match' if netgen_match else 'mismatch'} — "
            f"see {netgen_log} and {layout_spice}"
        )
