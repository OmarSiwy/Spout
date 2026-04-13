"""
Shared fixtures for ``tests/verification``.

All klayout-dependent tests import :func:`klayout_available` or use
``pytest.importorskip('klayout.db')`` so that CI without the klayout
package still reports green.
"""

from __future__ import annotations

from pathlib import Path

import pytest


@pytest.fixture(scope="session")
def klayout_available() -> object:
    """Skip the test if ``klayout.db`` is not importable.

    Returns the imported module so individual tests can reach into it
    if they need low-level inspection.
    """
    return pytest.importorskip("klayout.db")


@pytest.fixture(scope="session")
def fixtures_dir() -> Path:
    """Absolute path to ``tests/fixture/verification``."""
    return Path(__file__).resolve().parent.parent / "fixture" / "verification"
