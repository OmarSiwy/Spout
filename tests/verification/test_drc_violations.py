"""Dirty fixture with known spacing violations should be detected."""

from __future__ import annotations


def test_dirty_spacing_reports_violations(klayout_available, fixtures_dir):
    from python.spout.config import SpoutConfig
    from python.verification import run_drc

    pdk = SpoutConfig(pdk="sky130")
    gds = fixtures_dir / "dirty_spacing.gds"

    report = run_drc(gds, pdk)

    assert not report.is_clean
    assert len(report.violations) > 0
    # Every reported violation must carry a non-empty rule name.
    for v in report.violations:
        assert v.rule
        assert v.severity in {"error", "warning"}
