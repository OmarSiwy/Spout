"""LVS match case — GDS and SPICE describe the same circuit."""

from __future__ import annotations


def test_matched_nmos_lvs_passes(klayout_available, fixtures_dir):
    from python.spout.config import SpoutConfig
    from python.verification import run_lvs

    pdk = SpoutConfig(pdk="sky130")
    gds = fixtures_dir / "matched.gds"
    netlist = fixtures_dir / "matched.spice"

    verdict = run_lvs(gds, netlist, pdk, top_cell="matched")

    assert verdict.matches
    assert verdict.device_mismatches == ()
