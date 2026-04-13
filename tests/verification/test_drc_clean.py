"""Clean fixture GDS should produce an empty DrcReport."""

from __future__ import annotations


def test_clean_simple_is_clean(klayout_available, fixtures_dir):
    from python.spout.config import SpoutConfig
    from python.verification import run_drc

    pdk = SpoutConfig(pdk="sky130")
    gds = fixtures_dir / "clean_simple.gds"

    report = run_drc(gds, pdk)

    assert report.is_clean
    assert len(report.violations) == 0
