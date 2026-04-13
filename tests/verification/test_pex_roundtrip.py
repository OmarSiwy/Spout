"""PEX roundtrip — simple two-wire cap should produce at least one C element."""

from __future__ import annotations


def test_cap_pair_produces_capacitance(klayout_available, fixtures_dir):
    from python.spout.config import SpoutConfig
    from python.verification import run_pex

    pdk = SpoutConfig(pdk="sky130")
    gds = fixtures_dir / "cap_pair.gds"

    report = run_pex(gds, pdk, top_cell="cap_pair")

    assert isinstance(report.spice_netlist, str)
    # At least one capacitor must be extracted for two parallel wires.
    caps = [e for e in report.elements if e.kind == "c"]
    assert len(caps) >= 1
    for c in caps:
        assert c.value > 0.0
