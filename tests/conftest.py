"""Shared fixtures for the Spout test suite."""

from __future__ import annotations

import os
import pathlib
import sys

# ---------------------------------------------------------------------------
# Make `import spout` work without pip install.
# pyproject.toml maps package "spout" -> directory "python/", so we add
# the project root to sys.path and create a path mapping via a .pth-style
# approach: insert the parent so that "python/" is findable, then alias.
# ---------------------------------------------------------------------------

PROJECT_ROOT = pathlib.Path(__file__).resolve().parent.parent
_python_dir = str(PROJECT_ROOT / "python")
if _python_dir not in sys.path:
    sys.path.insert(0, _python_dir)

# Register "python/" as the "spout" package so `from spout.X import Y` works.
if "spout" not in sys.modules:
    import importlib
    spec = importlib.util.spec_from_file_location(
        "spout",
        str(PROJECT_ROOT / "python" / "__init__.py"),
        submodule_search_locations=[_python_dir],
    )
    if spec and spec.loader:
        mod = importlib.util.module_from_spec(spec)
        sys.modules["spout"] = mod
        spec.loader.exec_module(mod)

import pytest
BENCHMARKS_DIR = PROJECT_ROOT / "fixtures" / "benchmark"
LIBSPOUT_PATH = PROJECT_ROOT / "python" / "libspout.so"
CURRENT_MIRROR = BENCHMARKS_DIR / "current_mirror.spice"
DIFF_PAIR = BENCHMARKS_DIR / "diff_pair.spice"


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------


@pytest.fixture
def tmp_output_dir(tmp_path: pathlib.Path) -> pathlib.Path:
    """Provide a temporary directory for pipeline output files."""
    out = tmp_path / "spout_test_output"
    out.mkdir(parents=True, exist_ok=True)
    return out


@pytest.fixture
def ffi_instance():
    """Provide a SpoutFFI instance, skipping if libspout.so is missing."""
    if not LIBSPOUT_PATH.exists():
        pytest.skip(f"libspout.so not found at {LIBSPOUT_PATH}")

    from spout.ffi import SpoutFFI

    return SpoutFFI(lib_path=str(LIBSPOUT_PATH))


@pytest.fixture
def ffi_handle(ffi_instance):
    """Provide a (ffi, handle) tuple with backend=klayout(1), pdk=sky130(0).

    The handle is automatically destroyed after the test.
    """
    handle = ffi_instance.init_layout(backend=1, pdk=0)
    yield ffi_instance, handle
    ffi_instance.destroy(handle)


@pytest.fixture
def test_config():
    """Provide a SpoutConfig suitable for testing.

    Uses klayout backend (avoids magic buffer overflow bug) and sky130 PDK.
    SA iterations are reduced to keep tests fast.
    """
    from spout.config import SpoutConfig, SaConfig

    sa = SaConfig(
        initial_temp=100.0,
        cooling_rate=0.95,
        min_temp=1.0,
        max_iterations=500,
        perturbation_range=5.0,
    )
    return SpoutConfig(
        backend="klayout",
        pdk="sky130",
        use_ml=False,
        use_gradient=False,
        use_repair=False,
        sa_config=sa,
    )
