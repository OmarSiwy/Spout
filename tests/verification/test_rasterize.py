"""
``rasterize_violations`` must turn a DrcReport into a HxW uint8 mask.

This test does not require klayout — it constructs a synthetic
:class:`DrcReport` by hand and checks the output shape and cell values.
"""

from __future__ import annotations

from pathlib import Path

import numpy as np

from python.verification import DrcReport, DrcViolation, rasterize_violations


def _make_report(violations):
    return DrcReport(
        gds_path=Path("/tmp/fake.gds"),
        top_cell="TOP",
        violations=tuple(violations),
    )


def test_empty_report_produces_zero_mask():
    report = _make_report([])
    mask = rasterize_violations(report, grid_nm=100, extent=(0, 0, 10_000, 10_000))
    assert mask.shape == (100, 100)
    assert mask.dtype == np.uint8
    assert mask.sum() == 0


def test_two_violations_mark_expected_cells():
    # Violation 1: box (1.0, 2.0, 2.0, 3.0) um → nm (1000, 2000, 2000, 3000).
    # With grid_nm=100 inside extent (0,0,10000,10000):
    #   col_start=10, col_end=20, row_start=20, row_end=30 → 10x10 cells.
    v1 = DrcViolation(
        rule="spacing",
        layer=67,
        bbox=(1.0, 2.0, 2.0, 3.0),
        severity="error",
    )
    # Violation 2: box (5.0, 5.0, 5.5, 5.5) um → nm (5000,5000,5500,5500).
    #   col_start=50, col_end=55, row_start=50, row_end=55 → 5x5 cells.
    v2 = DrcViolation(
        rule="min_area",
        layer=67,
        bbox=(5.0, 5.0, 5.5, 5.5),
        severity="error",
    )
    report = _make_report([v1, v2])

    mask = rasterize_violations(report, grid_nm=100, extent=(0, 0, 10_000, 10_000))

    assert mask.shape == (100, 100)
    assert mask.dtype == np.uint8

    # Violation 1 region.
    assert mask[20:30, 10:20].all()
    assert mask[20:30, 10:20].sum() == 100

    # Violation 2 region.
    assert mask[50:55, 50:55].all()
    assert mask[50:55, 50:55].sum() == 25

    # Total set cells = 100 + 25.
    assert int(mask.sum()) == 125


def test_violation_outside_extent_is_clipped():
    v = DrcViolation(
        rule="spacing",
        layer=67,
        bbox=(100.0, 100.0, 200.0, 200.0),
        severity="error",
    )
    report = _make_report([v])
    mask = rasterize_violations(report, grid_nm=100, extent=(0, 0, 10_000, 10_000))
    assert mask.sum() == 0


def test_invalid_grid_raises():
    import pytest

    report = _make_report([])
    with pytest.raises(ValueError):
        rasterize_violations(report, grid_nm=0, extent=(0, 0, 10_000, 10_000))
    with pytest.raises(ValueError):
        rasterize_violations(report, grid_nm=100, extent=(10, 10, 10, 10))
