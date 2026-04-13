"""LVS mismatch case — GDS has an NMOS, netlist says PMOS."""

from __future__ import annotations


def test_mismatched_device_type_fails(klayout_available, fixtures_dir):
    from python.spout.config import SpoutConfig
    from python.verification import run_lvs

    pdk = SpoutConfig(pdk="sky130")
    gds = fixtures_dir / "mismatched.gds"
    netlist = fixtures_dir / "mismatched.spice"

    verdict = run_lvs(gds, netlist, pdk, top_cell="mismatched")

    assert not verdict.matches
    assert len(verdict.device_mismatches) > 0
