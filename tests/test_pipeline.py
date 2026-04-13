"""Comprehensive test suite for the Spout analog layout automation pipeline.

Test groups:
    1. Config tests — SpoutConfig creation, validation, SaConfig serialization
    2. FFI tests — loading libspout.so, lifecycle, parsing, SA, routing, DRC, GDSII
    3. Pipeline integration tests — full run_pipeline() on small benchmarks
    4. ML model tests — surrogate, unet, constraint, paragraph, gcnrl
    5. Training smoke tests — 2-epoch runs of surrogate and unet training

Run with:
    PYTHONPATH=python .venv/bin/python -m pytest tests/ -v
"""

from __future__ import annotations

import json
import os
import pathlib
import sys

import numpy as np
import pytest

from conftest import (
    BENCHMARKS_DIR,
    CURRENT_MIRROR,
    DIFF_PAIR,
    LIBSPOUT_PATH,
    PROJECT_ROOT,
)

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

_has_torch = False
try:
    import torch

    _has_torch = True
except ImportError:
    pass

_has_torch_geometric = False
try:
    import torch_geometric  # noqa: F401

    _has_torch_geometric = True
except ImportError:
    pass

requires_torch = pytest.mark.skipif(
    not _has_torch, reason="PyTorch not available"
)
requires_torch_geometric = pytest.mark.skipif(
    not _has_torch_geometric, reason="torch_geometric not available"
)
requires_libspout = pytest.mark.skipif(
    not LIBSPOUT_PATH.exists(), reason="libspout.so not built"
)


# =========================================================================
# 1. Config tests
# =========================================================================


class TestSpoutConfig:
    """SpoutConfig creation, validation, and property behaviour."""

    def test_default_creation(self):
        from spout.config import SpoutConfig

        cfg = SpoutConfig()
        assert cfg.backend == "magic"
        assert cfg.pdk == "sky130"
        assert cfg.backend_id == 0
        assert cfg.pdk_id == 0
        assert cfg.use_ml is False
        assert cfg.use_gradient is False
        assert cfg.use_repair is False
        assert cfg.max_repair_iterations == 5

    def test_klayout_sky130(self):
        from spout.config import SpoutConfig

        cfg = SpoutConfig(backend="klayout", pdk="sky130")
        assert cfg.backend_id == 1
        assert cfg.pdk_id == 0

    def test_all_backends(self):
        from spout.config import SpoutConfig

        for name, expected_id in SpoutConfig.BACKENDS.items():
            cfg = SpoutConfig(backend=name)
            assert cfg.backend_id == expected_id

    def test_all_pdks(self):
        from spout.config import SpoutConfig

        for name, expected_id in SpoutConfig.PDKS.items():
            cfg = SpoutConfig(pdk=name)
            assert cfg.pdk_id == expected_id

    def test_invalid_backend_raises(self):
        from spout.config import SpoutConfig

        with pytest.raises(ValueError, match="Unknown backend"):
            SpoutConfig(backend="nonexistent")

    def test_invalid_pdk_raises(self):
        from spout.config import SpoutConfig

        with pytest.raises(ValueError, match="Unknown PDK"):
            SpoutConfig(pdk="nonexistent")

    def test_pdk_root_from_env(self, monkeypatch):
        from spout.config import SpoutConfig

        monkeypatch.setenv("PDK_ROOT", "/fake/pdk/root")
        cfg = SpoutConfig()
        assert cfg.pdk_root == "/fake/pdk/root"

    def test_pdk_root_explicit_overrides_env(self, monkeypatch):
        from spout.config import SpoutConfig

        monkeypatch.setenv("PDK_ROOT", "/env/path")
        cfg = SpoutConfig(pdk_root="/explicit/path")
        assert cfg.pdk_root == "/explicit/path"

    def test_pdk_variant_root_sky130(self):
        from spout.config import SpoutConfig

        cfg = SpoutConfig(pdk="sky130", pdk_root="/pdk")
        assert cfg.pdk_variant_root == "/pdk/sky130A"

    def test_pdk_variant_root_gf180(self):
        from spout.config import SpoutConfig

        cfg = SpoutConfig(pdk="gf180", pdk_root="/pdk")
        assert cfg.pdk_variant_root == "/pdk/gf180mcuD"

    def test_tech_file_path(self):
        from spout.config import SpoutConfig

        cfg = SpoutConfig(backend="klayout", pdk="sky130", pdk_root="/pdk")
        assert cfg.tech_file.endswith("sky130A.lyt")
        assert "/pdk/sky130A/" in cfg.tech_file

    def test_netgen_setup_path(self):
        from spout.config import SpoutConfig

        cfg = SpoutConfig(pdk="sky130", pdk_root="/pdk")
        assert cfg.netgen_setup.endswith("sky130A_setup.tcl")

    def test_repr(self):
        from spout.config import SpoutConfig

        cfg = SpoutConfig(backend="klayout", pdk="sky130", use_ml=True)
        r = repr(cfg)
        assert "klayout" in r
        assert "sky130" in r
        assert "use_ml=True" in r

    def test_custom_sa_config(self):
        from spout.config import SpoutConfig, SaConfig

        sa = SaConfig(initial_temp=500.0, max_iterations=1000)
        cfg = SpoutConfig(sa_config=sa)
        assert cfg.sa_config.initial_temp == 500.0
        assert cfg.sa_config.max_iterations == 1000

    def test_output_dir_default(self):
        from spout.config import SpoutConfig

        cfg = SpoutConfig()
        assert cfg.output_dir == "spout_output"

    def test_output_dir_custom(self):
        from spout.config import SpoutConfig

        cfg = SpoutConfig(output_dir="/tmp/my_output")
        assert cfg.output_dir == "/tmp/my_output"


class TestSaConfig:
    """SaConfig serialization and defaults."""

    def test_defaults(self):
        from spout.config import SaConfig

        sa = SaConfig()
        assert sa.initial_temp == 1000.0
        assert sa.cooling_rate == 0.995
        assert sa.min_temp == 0.01
        assert sa.max_iterations == 50_000
        assert sa.perturbation_range == 10.0
        assert sa.w_hpwl == 1.0
        assert sa.w_area == 0.5
        assert sa.w_symmetry == 2.0
        assert sa.w_matching == 1.5
        assert sa.w_rudy == 0.3

    def test_to_json_bytes_returns_bytes(self):
        from spout.config import SaConfig

        sa = SaConfig()
        result = sa.to_json_bytes()
        assert isinstance(result, bytes)

    def test_to_json_bytes_valid_json(self):
        from spout.config import SaConfig

        sa = SaConfig(initial_temp=123.0, max_iterations=999)
        data = json.loads(sa.to_json_bytes())
        assert data["initial_temp"] == 123.0
        assert data["max_iterations"] == 999

    def test_to_json_bytes_all_fields_present(self):
        from spout.config import SaConfig

        sa = SaConfig()
        data = json.loads(sa.to_json_bytes())
        expected_keys = {
            "initial_temp",
            "cooling_rate",
            "min_temp",
            "max_iterations",
            "perturbation_range",
            "w_hpwl",
            "w_area",
            "w_symmetry",
            "w_matching",
            "w_rudy",
        }
        assert set(data.keys()) == expected_keys

    def test_to_json_bytes_compact(self):
        from spout.config import SaConfig

        sa = SaConfig()
        raw = sa.to_json_bytes()
        # Compact JSON should not have spaces after separators.
        assert b" " not in raw


# =========================================================================
# 2. FFI tests
# =========================================================================


@requires_libspout
class TestFFILoading:
    """Loading libspout.so and basic lifecycle."""

    def test_load_library(self, ffi_instance):
        assert ffi_instance.lib is not None

    def test_init_destroy_lifecycle(self, ffi_instance):
        handle = ffi_instance.init_layout(backend=1, pdk=0)
        assert handle is not None
        assert handle != 0
        ffi_instance.destroy(handle)

    def test_init_magic_backend(self, ffi_instance):
        handle = ffi_instance.init_layout(backend=0, pdk=0)
        assert handle is not None
        ffi_instance.destroy(handle)

    def test_init_all_pdks(self, ffi_instance):
        for pdk_id in range(3):  # sky130=0, gf180=1, ihp130=2
            handle = ffi_instance.init_layout(backend=1, pdk=pdk_id)
            assert handle is not None
            ffi_instance.destroy(handle)


@requires_libspout
class TestFFIParsing:
    """Netlist parsing through the FFI."""

    def test_parse_current_mirror(self, ffi_handle):
        ffi, handle = ffi_handle
        rc = ffi.parse_netlist(handle, str(CURRENT_MIRROR))
        assert rc == 0

    def test_device_count_current_mirror(self, ffi_handle):
        ffi, handle = ffi_handle
        ffi.parse_netlist(handle, str(CURRENT_MIRROR))
        n = ffi.get_num_devices(handle)
        assert n == 2, f"Expected 2 devices in current_mirror, got {n}"

    def test_net_count_current_mirror(self, ffi_handle):
        ffi, handle = ffi_handle
        ffi.parse_netlist(handle, str(CURRENT_MIRROR))
        n = ffi.get_num_nets(handle)
        assert n > 0, "Expected at least one net"

    def test_pin_count_current_mirror(self, ffi_handle):
        ffi, handle = ffi_handle
        ffi.parse_netlist(handle, str(CURRENT_MIRROR))
        n = ffi.get_num_pins(handle)
        # Each MOSFET has 4 terminals (D, G, S, B) -> 8 pins total.
        assert n >= 8, f"Expected at least 8 pins, got {n}"

    def test_parse_diff_pair(self, ffi_handle):
        ffi, handle = ffi_handle
        if not DIFF_PAIR.exists():
            pytest.skip("diff_pair.spice not found")
        rc = ffi.parse_netlist(handle, str(DIFF_PAIR))
        assert rc == 0

    def test_parse_nonexistent_file_raises(self, ffi_instance):
        # Use a separate handle. After a failed parse the Zig engine
        # leaves the context in a state where destroy segfaults, so we
        # intentionally skip destroy (accept the small leak in tests).
        handle = ffi_instance.init_layout(backend=1, pdk=0)
        with pytest.raises(RuntimeError, match="failed"):
            ffi_instance.parse_netlist(handle, "/nonexistent/path.spice")
        # NOTE: not calling destroy -- the Zig side may have partially freed
        # the handle after the error, and calling destroy segfaults.

    def test_device_positions_shape(self, ffi_handle):
        ffi, handle = ffi_handle
        ffi.parse_netlist(handle, str(CURRENT_MIRROR))
        pos = ffi.get_device_positions(handle)
        n = ffi.get_num_devices(handle)
        assert pos.shape == (n, 2)
        assert pos.dtype == np.float32

    def test_device_types_shape(self, ffi_handle):
        ffi, handle = ffi_handle
        ffi.parse_netlist(handle, str(CURRENT_MIRROR))
        types = ffi.get_device_types(handle)
        n = ffi.get_num_devices(handle)
        assert types.shape == (n,)
        assert types.dtype == np.uint8

    def test_device_params_shape(self, ffi_handle):
        ffi, handle = ffi_handle
        ffi.parse_netlist(handle, str(CURRENT_MIRROR))
        params = ffi.get_device_params(handle)
        n = ffi.get_num_devices(handle)
        assert params.shape == (n, 5)
        assert params.dtype == np.float32

    def test_device_params_structured(self, ffi_handle):
        ffi, handle = ffi_handle
        ffi.parse_netlist(handle, str(CURRENT_MIRROR))
        sp = ffi.get_device_params_structured(handle)
        n = ffi.get_num_devices(handle)
        assert len(sp) == n
        assert "w" in sp.dtype.names
        assert "l" in sp.dtype.names
        assert "fingers" in sp.dtype.names
        assert "mult" in sp.dtype.names
        assert "value" in sp.dtype.names

    def test_net_fanout_shape(self, ffi_handle):
        ffi, handle = ffi_handle
        ffi.parse_netlist(handle, str(CURRENT_MIRROR))
        fanout = ffi.get_net_fanout(handle)
        m = ffi.get_num_nets(handle)
        assert fanout.shape == (m,)
        assert fanout.dtype == np.uint16

    def test_pin_device_shape(self, ffi_handle):
        ffi, handle = ffi_handle
        ffi.parse_netlist(handle, str(CURRENT_MIRROR))
        pd = ffi.get_pin_device(handle)
        p = ffi.get_num_pins(handle)
        assert pd.shape == (p,)
        assert pd.dtype == np.uint32

    def test_pin_net_shape(self, ffi_handle):
        ffi, handle = ffi_handle
        ffi.parse_netlist(handle, str(CURRENT_MIRROR))
        pn = ffi.get_pin_net(handle)
        p = ffi.get_num_pins(handle)
        assert pn.shape == (p,)
        assert pn.dtype == np.uint32

    def test_pin_terminal_shape(self, ffi_handle):
        ffi, handle = ffi_handle
        ffi.parse_netlist(handle, str(CURRENT_MIRROR))
        pt = ffi.get_pin_terminal(handle)
        p = ffi.get_num_pins(handle)
        assert pt.shape == (p,)
        assert pt.dtype == np.uint8

    def test_get_all_arrays(self, ffi_handle):
        ffi, handle = ffi_handle
        ffi.parse_netlist(handle, str(CURRENT_MIRROR))
        arrays = ffi.get_all_arrays(handle)
        assert "device_positions" in arrays
        assert "device_types" in arrays
        assert "device_params" in arrays
        assert "net_fanout" in arrays
        assert "pin_device" in arrays
        assert "pin_net" in arrays
        assert "pin_terminal" in arrays
        assert "num_devices" in arrays
        assert "num_nets" in arrays
        assert "num_pins" in arrays
        assert arrays["num_devices"] == 2


@requires_libspout
class TestFFIConstraints:
    """Constraint extraction through the FFI."""

    def test_extract_constraints(self, ffi_handle):
        ffi, handle = ffi_handle
        ffi.parse_netlist(handle, str(CURRENT_MIRROR))
        rc = ffi.extract_constraints(handle)
        assert rc == 0

    def test_get_constraints_returns_bytes(self, ffi_handle):
        ffi, handle = ffi_handle
        ffi.parse_netlist(handle, str(CURRENT_MIRROR))
        ffi.extract_constraints(handle)
        data = ffi.get_constraints(handle)
        assert isinstance(data, bytes)


@requires_libspout
class TestFFIPlacement:
    """SA placement through the FFI."""

    def test_sa_placement(self, ffi_handle):
        from spout.config import SaConfig

        ffi, handle = ffi_handle
        ffi.parse_netlist(handle, str(CURRENT_MIRROR))
        ffi.extract_constraints(handle)

        sa = SaConfig(max_iterations=100, initial_temp=100.0, cooling_rate=0.9)
        rc = ffi.run_sa_placement(handle, sa.to_json_bytes())
        assert rc == 0

    def test_placement_cost_is_finite(self, ffi_handle):
        from spout.config import SaConfig

        ffi, handle = ffi_handle
        ffi.parse_netlist(handle, str(CURRENT_MIRROR))
        ffi.extract_constraints(handle)

        sa = SaConfig(max_iterations=100, initial_temp=100.0, cooling_rate=0.9)
        ffi.run_sa_placement(handle, sa.to_json_bytes())

        cost = ffi.get_placement_cost(handle)
        assert np.isfinite(cost), f"Placement cost is not finite: {cost}"

    def test_positions_change_after_placement(self, ffi_handle):
        from spout.config import SaConfig

        ffi, handle = ffi_handle
        ffi.parse_netlist(handle, str(CURRENT_MIRROR))
        ffi.extract_constraints(handle)

        pos_before = ffi.get_device_positions(handle).copy()

        sa = SaConfig(max_iterations=500, initial_temp=100.0, cooling_rate=0.9)
        ffi.run_sa_placement(handle, sa.to_json_bytes())

        pos_after = ffi.get_device_positions(handle)
        # After SA placement, at least one device should have moved.
        assert not np.allclose(
            pos_before, pos_after, atol=1e-6
        ), "No devices moved during SA placement"


@requires_libspout
class TestFFIRouting:
    """Routing through the FFI."""

    def test_routing_after_placement(self, ffi_handle):
        from spout.config import SaConfig

        ffi, handle = ffi_handle
        ffi.parse_netlist(handle, str(CURRENT_MIRROR))
        ffi.extract_constraints(handle)

        sa = SaConfig(max_iterations=100, initial_temp=100.0, cooling_rate=0.9)
        ffi.run_sa_placement(handle, sa.to_json_bytes())

        rc = ffi.run_routing(handle)
        assert rc == 0

    def test_route_count_positive(self, ffi_handle):
        from spout.config import SaConfig

        ffi, handle = ffi_handle
        ffi.parse_netlist(handle, str(CURRENT_MIRROR))
        ffi.extract_constraints(handle)

        sa = SaConfig(max_iterations=100, initial_temp=100.0, cooling_rate=0.9)
        ffi.run_sa_placement(handle, sa.to_json_bytes())
        ffi.run_routing(handle)

        n_routes = ffi.get_num_routes(handle)
        assert n_routes > 0, "Expected at least one route segment"

    def test_route_segments_shape(self, ffi_handle):
        from spout.config import SaConfig

        ffi, handle = ffi_handle
        ffi.parse_netlist(handle, str(CURRENT_MIRROR))
        ffi.extract_constraints(handle)

        sa = SaConfig(max_iterations=100, initial_temp=100.0, cooling_rate=0.9)
        ffi.run_sa_placement(handle, sa.to_json_bytes())
        ffi.run_routing(handle)

        segments = ffi.get_route_segments(handle)
        n_routes = ffi.get_num_routes(handle)
        assert segments.shape == (n_routes, 7)
        assert segments.dtype == np.float32


@pytest.mark.xfail(
    reason=(
        "In-engine DRC FFI bindings removed in the KLayout migration "
        "(src/verify deleted). Wave 2 will expose equivalent checks "
        "through python.verification. See "
        "docs/superpowers/specs/2026-04-07-replace-in-engine-verify-with-klayout-design.md"
    ),
    strict=False,
)
@requires_libspout
class TestFFIDRC:
    """DRC checking through the FFI."""

    def test_run_drc(self, ffi_handle):
        from spout.config import SaConfig

        ffi, handle = ffi_handle
        ffi.parse_netlist(handle, str(CURRENT_MIRROR))
        ffi.extract_constraints(handle)

        sa = SaConfig(max_iterations=100, initial_temp=100.0, cooling_rate=0.9)
        ffi.run_sa_placement(handle, sa.to_json_bytes())
        ffi.run_routing(handle)

        rc = ffi.run_drc(handle)
        assert rc == 0

    def test_get_num_violations_is_int(self, ffi_handle):
        from spout.config import SaConfig

        ffi, handle = ffi_handle
        ffi.parse_netlist(handle, str(CURRENT_MIRROR))
        ffi.extract_constraints(handle)

        sa = SaConfig(max_iterations=100, initial_temp=100.0, cooling_rate=0.9)
        ffi.run_sa_placement(handle, sa.to_json_bytes())
        ffi.run_routing(handle)
        ffi.run_drc(handle)

        n = ffi.get_num_violations(handle)
        assert isinstance(n, int)
        assert n >= 0

    def test_get_drc_violations_returns_list(self, ffi_handle):
        from spout.config import SaConfig

        ffi, handle = ffi_handle
        ffi.parse_netlist(handle, str(CURRENT_MIRROR))
        ffi.extract_constraints(handle)

        sa = SaConfig(max_iterations=100, initial_temp=100.0, cooling_rate=0.9)
        ffi.run_sa_placement(handle, sa.to_json_bytes())
        ffi.run_routing(handle)
        ffi.run_drc(handle)

        violations = ffi.get_drc_violations(handle)
        assert isinstance(violations, list)
        if violations:
            v = violations[0]
            assert "rule" in v
            assert "layer" in v
            assert "x" in v
            assert "y" in v
            assert "actual" in v
            assert "required" in v


@requires_libspout
class TestFFIExport:
    """GDSII export through the FFI."""

    def test_export_gdsii(self, ffi_handle, tmp_output_dir):
        from spout.config import SaConfig

        ffi, handle = ffi_handle
        ffi.parse_netlist(handle, str(CURRENT_MIRROR))
        ffi.extract_constraints(handle)

        sa = SaConfig(max_iterations=100, initial_temp=100.0, cooling_rate=0.9)
        ffi.run_sa_placement(handle, sa.to_json_bytes())
        ffi.run_routing(handle)

        gds_path = str(tmp_output_dir / "test_export.gds")
        rc = ffi.export_gdsii(handle, gds_path)
        assert rc == 0
        assert os.path.exists(gds_path)
        assert os.path.getsize(gds_path) > 0


@requires_libspout
class TestFFIMLWriteback:
    """ML array write-back through the FFI."""

    def test_set_device_embeddings(self, ffi_handle):
        ffi, handle = ffi_handle
        ffi.parse_netlist(handle, str(CURRENT_MIRROR))

        n = ffi.get_num_devices(handle)
        emb = np.zeros((n, 64), dtype=np.float32)
        rc = ffi.set_device_embeddings(handle, emb)
        assert rc == 0

    def test_set_net_embeddings(self, ffi_handle):
        ffi, handle = ffi_handle
        ffi.parse_netlist(handle, str(CURRENT_MIRROR))

        m = ffi.get_num_nets(handle)
        emb = np.zeros((m, 64), dtype=np.float32)
        rc = ffi.set_net_embeddings(handle, emb)
        assert rc == 0

    def test_set_predicted_cap(self, ffi_handle):
        ffi, handle = ffi_handle
        ffi.parse_netlist(handle, str(CURRENT_MIRROR))

        n = ffi.get_num_devices(handle)
        caps = np.ones(n, dtype=np.float32)
        rc = ffi.set_predicted_cap(handle, caps)
        assert rc == 0


# =========================================================================
# 3. Pipeline integration tests
# =========================================================================


@requires_libspout
class TestPipelineIntegration:
    """Full run_pipeline() integration tests."""

    def test_run_pipeline_current_mirror(self, test_config, tmp_output_dir):
        from spout.pipeline import run_pipeline

        gds_path = str(tmp_output_dir / "current_mirror.gds")
        result = run_pipeline(
            netlist_path=str(CURRENT_MIRROR),
            config=test_config,
            output_path=gds_path,
        )

        assert result.gds_path == os.path.abspath(gds_path)
        assert result.error is None, f"Pipeline error: {result.error}"
        assert result.num_devices == 2
        assert result.num_nets > 0
        assert result.num_routes > 0
        assert np.isfinite(result.placement_cost)
        assert os.path.exists(result.gds_path)
        assert os.path.getsize(result.gds_path) > 0
        # LVS must run (not be silently skipped)
        assert result.timings.lvs > 0, "LVS was skipped"
        assert isinstance(result.lvs_clean, bool)

    def test_pipeline_produces_gds_file(self, test_config, tmp_output_dir):
        from spout.pipeline import run_pipeline

        gds_path = str(tmp_output_dir / "output.gds")
        result = run_pipeline(
            netlist_path=str(CURRENT_MIRROR),
            config=test_config,
            output_path=gds_path,
        )
        assert os.path.isfile(result.gds_path)

    def test_pipeline_timings_populated(self, test_config, tmp_output_dir):
        from spout.pipeline import run_pipeline

        gds_path = str(tmp_output_dir / "timings_test.gds")
        result = run_pipeline(
            netlist_path=str(CURRENT_MIRROR),
            config=test_config,
            output_path=gds_path,
        )
        assert result.timings.parse > 0
        assert result.timings.placement > 0
        assert result.timings.routing > 0
        assert result.timings.export > 0
        assert result.timings.lvs > 0, "LVS was skipped"
        assert result.timings.total > 0

    def test_pipeline_with_provided_ffi(
        self, test_config, tmp_output_dir, ffi_instance
    ):
        from spout.pipeline import run_pipeline

        gds_path = str(tmp_output_dir / "with_ffi.gds")
        result = run_pipeline(
            netlist_path=str(CURRENT_MIRROR),
            config=test_config,
            output_path=gds_path,
            ffi=ffi_instance,
        )
        assert result.error is None, f"Pipeline error: {result.error}"
        assert result.num_devices == 2
        assert result.timings.lvs > 0, "LVS was skipped"
        assert isinstance(result.lvs_clean, bool)

    @pytest.mark.skip(
        reason="Known Zig bug: spout_destroy segfaults after a failed parse"
    )
    def test_pipeline_nonexistent_netlist_returns_error(
        self, test_config, tmp_output_dir
    ):
        from spout.pipeline import run_pipeline

        gds_path = str(tmp_output_dir / "fail.gds")
        result = run_pipeline(
            netlist_path="/nonexistent/path.spice",
            config=test_config,
            output_path=gds_path,
        )
        assert result.success is False
        assert result.error is not None

    def test_pipeline_diff_pair(self, test_config, tmp_output_dir):
        from spout.pipeline import run_pipeline

        if not DIFF_PAIR.exists():
            pytest.skip("diff_pair.spice not found")

        gds_path = str(tmp_output_dir / "diff_pair.gds")
        result = run_pipeline(
            netlist_path=str(DIFF_PAIR),
            config=test_config,
            output_path=gds_path,
        )
        assert result.error is None, f"Pipeline error: {result.error}"
        assert result.num_devices > 0
        assert os.path.exists(result.gds_path)
        assert result.timings.lvs > 0, "LVS was skipped"
        assert isinstance(result.lvs_clean, bool)


# ---------------------------------------------------------------------------
# Full-sweep: run the pipeline against every input benchmark netlist.
# Excludes *_lvs*.spice and *_pex*.spice (those are extraction artifacts
# produced by earlier runs, not input designs).
#
# This sweep does NOT enforce DRC-clean or LVS-clean as a pass criterion —
# it asserts only that the pipeline runs to completion and emits a GDS.
# The real DRC/LVS/PEX numbers are collected and printed as a summary
# table at session teardown so you can see the current signoff reality.
# ---------------------------------------------------------------------------

def _collect_input_benchmarks() -> list[pathlib.Path]:
    if not BENCHMARKS_DIR.exists():
        return []
    return sorted(
        p
        for p in BENCHMARKS_DIR.glob("*.spice")
        if "_lvs" not in p.stem and "_pex" not in p.stem
    )


_ALL_BENCHMARKS = _collect_input_benchmarks()


@pytest.fixture(scope="session")
def sweep_results(request):
    """Collects per-netlist pipeline metrics and prints a table at teardown."""
    rows: list[dict] = []

    def report():
        if not rows:
            return
        rows.sort(key=lambda r: r["name"])
        width = 100
        print("\n\n" + "=" * width)
        print("Pipeline sweep — DRC / LVS / PEX per benchmark (use_ml=False)")
        print("=" * width)
        header = (
            f"{'netlist':<44} {'devs':>5} {'DRC':>5} {'LVS':>5} "
            f"{'PEX':>10} {'R(Ω)':>9} {'C(fF)':>9} {'time':>7}"
        )
        print(header)
        print("-" * width)
        drc_clean = lvs_clean = 0
        for r in rows:
            lvs_str = "ok" if r["lvs"] else "FAIL"
            drc_str = str(r["drc"]) if r["drc"] >= 0 else "n/a"
            pex_str = r["pex"] or "-"
            print(
                f"{r['name']:<44} {r['devs']:>5} {drc_str:>5} {lvs_str:>5} "
                f"{pex_str:>10} {r['R']:>9.1f} {r['C']:>9.2f} {r['time']:>6.1f}s"
            )
            if r["drc"] == 0:
                drc_clean += 1
            if r["lvs"]:
                lvs_clean += 1
        print("-" * width)
        print(
            f"Summary: {len(rows)} netlists | "
            f"DRC-clean: {drc_clean}/{len(rows)} | "
            f"LVS-clean: {lvs_clean}/{len(rows)}"
        )
        print("=" * width)

    request.addfinalizer(report)
    return rows


@requires_libspout
class TestPipelineSweep:
    """Run the full pipeline (use_ml=False) against every input benchmark.

    One test per netlist so failures are attributed per-design.  Correctness
    bar here is: pipeline completes without error and emits a non-empty GDS.
    DRC/LVS/PEX numbers are recorded for the summary table but not asserted.
    """

    @pytest.mark.parametrize(
        "netlist",
        _ALL_BENCHMARKS,
        ids=[p.stem for p in _ALL_BENCHMARKS],
    )
    def test_pipeline_runs_on_benchmark(
        self,
        netlist: pathlib.Path,
        test_config,
        tmp_output_dir,
        sweep_results,
    ):
        from spout.pipeline import run_pipeline

        gds_path = str(tmp_output_dir / f"{netlist.stem}.gds")
        result = run_pipeline(
            netlist_path=str(netlist),
            config=test_config,
            output_path=gds_path,
        )

        pex = result.pex_assessment
        sweep_results.append(
            {
                "name": netlist.stem,
                "devs": result.num_devices,
                "drc": result.drc_violations,
                "lvs": result.lvs_clean,
                "pex": pex.rating if pex else None,
                "R": pex.total_res_ohm if pex else 0.0,
                "C": pex.total_cap_ff if pex else 0.0,
                "time": result.timings.total,
            }
        )

        assert result.error is None, f"Pipeline error on {netlist.name}: {result.error}"
        assert result.num_devices > 0, f"{netlist.name}: no devices parsed"
        assert os.path.exists(result.gds_path), f"{netlist.name}: GDS not written"
        assert os.path.getsize(result.gds_path) > 0, f"{netlist.name}: GDS empty"


@requires_libspout
class TestKLayoutLVS:
    """KLayout LVS signoff must detect mismatches."""

    def test_lvs_runs_and_reports_mismatch(self, test_config, tmp_output_dir):
        """LVS must actually execute (no deck-path crash) and flag mismatches."""
        from spout.pipeline import run_pipeline

        gds_path = str(tmp_output_dir / "lvs_current_mirror.gds")
        result = run_pipeline(
            netlist_path=str(CURRENT_MIRROR),
            config=test_config,
            output_path=gds_path,
        )
        assert result.error is None, f"Pipeline error: {result.error}"
        # LVS should have run (lvs timing > 0) and reported a clean bool,
        # not silently skipped.  With the current auto-generated layout the
        # extracted netlist won't match the schematic, so lvs_clean is False.
        assert result.timings.lvs > 0, "LVS was skipped — deck path or binary issue"
        assert result.lvs_clean is False, (
            "LVS unexpectedly clean — verify KLayout actually compared the netlists"
        )
        assert result.success is False, (
            "Pipeline should report failure when LVS mismatches"
        )


class TestStageTimings:
    """StageTimings dataclass behaviour."""

    def test_total_sums_all_fields(self):
        from spout.pipeline import StageTimings

        t = StageTimings(
            parse=1.0,
            constraints=2.0,
            ml_encode=3.0,
            placement=4.0,
            gradient=5.0,
            routing=6.0,
            export=7.0,
            drc=8.0,
            lvs=9.0,
            pex=10.0,
            repair=11.0,
        )
        assert t.total == 66.0

    def test_default_zero(self):
        from spout.pipeline import StageTimings

        t = StageTimings()
        assert t.total == 0.0


class TestPipelineResult:
    """PipelineResult dataclass behaviour."""

    def test_creation(self):
        from spout.pipeline import PipelineResult

        r = PipelineResult(
            gds_path="/tmp/out.gds",
            drc_violations=0,
            lvs_clean=True,
            success=True,
        )
        assert r.success is True
        assert r.drc_violations == 0
        assert r.error is None
        assert r.placement_cost == 0.0


# =========================================================================
# 4. ML model tests
# =========================================================================


@requires_torch
class TestSurrogateCostMLP:
    """Surrogate cost MLP model creation and forward pass."""

    def test_create_model(self):
        from ml_surrogate.model import SurrogateCostMLP

        model = SurrogateCostMLP()
        assert model.in_features == 69
        assert model.out_features == 4

    def test_build_model(self):
        from ml_surrogate.model import build_model

        model = build_model()
        assert model is not None

    def test_forward_pass_shape(self):
        from ml_surrogate.model import SurrogateCostMLP

        model = SurrogateCostMLP()
        model.eval()
        x = torch.randn(8, 69)
        with torch.no_grad():
            y = model(x)
        assert y.shape == (8, 4)

    def test_forward_pass_single_sample(self):
        from ml_surrogate.model import SurrogateCostMLP

        model = SurrogateCostMLP()
        model.eval()
        x = torch.randn(1, 69)
        with torch.no_grad():
            y = model(x)
        assert y.shape == (1, 4)

    def test_custom_dimensions(self):
        from ml_surrogate.model import SurrogateCostMLP

        model = SurrogateCostMLP(in_features=32, out_features=2, hidden_dims=(64, 32))
        model.eval()
        x = torch.randn(4, 32)
        with torch.no_grad():
            y = model(x)
        assert y.shape == (4, 2)

    def test_parameter_count(self):
        from ml_surrogate.model import SurrogateCostMLP

        model = SurrogateCostMLP()
        total = sum(p.numel() for p in model.parameters())
        assert total > 0

    def test_gradients_flow(self):
        from ml_surrogate.model import SurrogateCostMLP

        model = SurrogateCostMLP()
        model.train()
        x = torch.randn(4, 69)
        y = model(x)
        loss = y.sum()
        loss.backward()
        for p in model.parameters():
            if p.requires_grad:
                assert p.grad is not None


@requires_torch
class TestUNetRepair:
    """UNet repair model creation and forward pass."""

    def test_create_model(self):
        from ml_unet.model import UNetRepair

        model = UNetRepair()
        assert model is not None

    def test_build_model(self):
        from ml_unet.model import build_model

        model = build_model()
        assert model is not None

    def test_forward_pass_shape(self):
        from ml_unet.model import UNetRepair, IN_CHANNELS, IMG_SIZE

        model = UNetRepair()
        model.eval()
        x = torch.randn(2, IN_CHANNELS, IMG_SIZE, IMG_SIZE)
        with torch.no_grad():
            y = model(x)
        assert y.shape == (2, IN_CHANNELS, IMG_SIZE, IMG_SIZE)

    def test_forward_pass_single_sample(self):
        from ml_unet.model import UNetRepair

        model = UNetRepair()
        model.eval()
        x = torch.randn(1, 5, 256, 256)
        with torch.no_grad():
            y = model(x)
        assert y.shape == (1, 5, 256, 256)

    def test_custom_channels(self):
        from ml_unet.model import UNetRepair

        model = UNetRepair(in_channels=3, out_channels=3, base_features=32)
        model.eval()
        x = torch.randn(1, 3, 256, 256)
        with torch.no_grad():
            y = model(x)
        assert y.shape == (1, 3, 256, 256)

    def test_parameter_count(self):
        from ml_unet.model import UNetRepair

        model = UNetRepair()
        total = sum(p.numel() for p in model.parameters())
        # UNet should have millions of parameters.
        assert total > 1_000_000

    def test_gradients_flow(self):
        from ml_unet.model import UNetRepair

        model = UNetRepair(base_features=16)  # Smaller for speed.
        model.train()
        x = torch.randn(1, 5, 64, 64)
        y = model(x)
        loss = y.sum()
        loss.backward()
        for p in model.parameters():
            if p.requires_grad:
                assert p.grad is not None


@requires_torch
@requires_torch_geometric
class TestConstraintGraphSAGE:
    """Constraint GNN model (requires torch_geometric)."""

    def test_create_model(self):
        from ml_constraint.model import ConstraintGraphSAGE

        model = ConstraintGraphSAGE()
        assert model is not None

    def test_build_model(self):
        from ml_constraint.model import build_model

        model = build_model()
        assert model is not None

    def test_forward_pass_shape(self):
        from ml_constraint.model import ConstraintGraphSAGE, DEVICE_FEAT_DIM

        model = ConstraintGraphSAGE()
        model.eval()
        n_nodes, n_edges = 30, 90
        x = torch.randn(n_nodes, DEVICE_FEAT_DIM)
        edge_index = torch.randint(0, n_nodes, (2, n_edges))
        with torch.no_grad():
            emb = model(x, edge_index)
        assert emb.shape == (n_nodes, 64)

    def test_embeddings_are_l2_normalized(self):
        from ml_constraint.model import ConstraintGraphSAGE, DEVICE_FEAT_DIM

        model = ConstraintGraphSAGE()
        model.eval()
        n_nodes = 20
        x = torch.randn(n_nodes, DEVICE_FEAT_DIM)
        edge_index = torch.randint(0, n_nodes, (2, 40))
        with torch.no_grad():
            emb = model(x, edge_index)
        norms = emb.norm(dim=-1)
        assert torch.allclose(
            norms, torch.ones(n_nodes), atol=1e-4
        ), f"Norms not ~1.0: {norms}"

    def test_predict_constraints(self):
        from ml_constraint.model import (
            ConstraintGraphSAGE,
            predict_constraints,
            DEVICE_FEAT_DIM,
        )

        model = ConstraintGraphSAGE()
        n_nodes = 20
        x = torch.randn(n_nodes, DEVICE_FEAT_DIM)
        edge_index = torch.randint(0, n_nodes, (2, 40))
        pairs, scores = predict_constraints(model, x, edge_index, threshold=0.0)
        assert pairs.ndim == 2
        if pairs.numel() > 0:
            assert pairs.shape[1] == 2
            assert scores.shape[0] == pairs.shape[0]


@requires_torch
@requires_torch_geometric
class TestParaGraphEnsemble:
    """ParaGraph parasitic predictor (requires torch_geometric)."""

    def test_create_model(self):
        from ml_paragraph.model import ParaGraphEnsemble

        model = ParaGraphEnsemble()
        assert model is not None

    def test_build_model(self):
        from ml_paragraph.model import build_model

        model = build_model()
        assert model is not None

    def test_forward_pass_shape(self):
        from ml_paragraph.model import (
            ParaGraphEnsemble,
            DEVICE_FEAT_DIM,
            NET_FEAT_DIM,
            NUM_RELATIONS,
        )

        model = ParaGraphEnsemble()
        model.eval()
        n_dev, n_net, n_edges = 20, 10, 60
        device_x = torch.randn(n_dev, DEVICE_FEAT_DIM)
        net_x = torch.randn(n_net, NET_FEAT_DIM)
        edge_index = torch.randint(0, n_dev + n_net, (2, n_edges))
        edge_type = torch.randint(0, NUM_RELATIONS, (n_edges,))

        with torch.no_grad():
            y = model(device_x, net_x, edge_index, edge_type, n_dev)
        assert y.shape == (n_dev,)

    def test_predict_helper(self):
        from ml_paragraph.model import (
            build_model,
            predict,
            DEVICE_FEAT_DIM,
            NET_FEAT_DIM,
            NUM_RELATIONS,
        )

        model = build_model()
        n_dev, n_net, n_edges = 10, 5, 30
        device_x = torch.randn(n_dev, DEVICE_FEAT_DIM)
        net_x = torch.randn(n_net, NET_FEAT_DIM)
        edge_index = torch.randint(0, n_dev + n_net, (2, n_edges))
        edge_type = torch.randint(0, NUM_RELATIONS, (n_edges,))

        y = predict(model, device_x, net_x, edge_index, edge_type, n_dev)
        assert y.shape == (n_dev,)


@requires_torch
@requires_torch_geometric
class TestGCNActorCritic:
    """GCN-RL placement agent (requires torch_geometric)."""

    def test_create_model(self):
        from ml_gcnrl.model import GCNActorCritic

        model = GCNActorCritic()
        assert model is not None

    def test_build_model(self):
        from ml_gcnrl.model import build_model

        model = build_model()
        assert model is not None

    def test_forward_pass_shapes(self):
        from ml_gcnrl.model import GCNActorCritic, NODE_FEAT_DIM, NUM_ACTIONS

        model = GCNActorCritic()
        model.eval()
        n_nodes, n_edges = 20, 60
        x = torch.randn(n_nodes, NODE_FEAT_DIM)
        edge_index = torch.randint(0, n_nodes, (2, n_edges))
        batch = torch.zeros(n_nodes, dtype=torch.long)
        current_idx = torch.tensor([0])

        with torch.no_grad():
            logits, values = model(x, edge_index, batch, current_idx)
        assert logits.shape == (1, NUM_ACTIONS)
        assert values.shape == (1, 1)

    def test_get_action_and_value(self):
        from ml_gcnrl.model import GCNActorCritic, NODE_FEAT_DIM

        model = GCNActorCritic()
        model.eval()
        n_nodes = 20
        x = torch.randn(n_nodes, NODE_FEAT_DIM)
        edge_index = torch.randint(0, n_nodes, (2, 40))
        batch = torch.zeros(n_nodes, dtype=torch.long)
        current_idx = torch.tensor([0])

        with torch.no_grad():
            action, log_prob, entropy, value = model.get_action_and_value(
                x, edge_index, batch, current_idx
            )
        assert action.shape == (1,)
        assert log_prob.shape == (1,)
        assert entropy.shape == (1,)
        assert value.shape == (1,)


# =========================================================================
# 5. Training smoke tests
# =========================================================================


@requires_torch
class TestSurrogateTraining:
    """Smoke test: run a few epochs of surrogate training."""

    def test_generate_synthetic_data(self):
        from ml_surrogate.train import generate_synthetic_data

        X, Y = generate_synthetic_data(n_samples=100, seed=0)
        assert X.shape == (100, 69)
        assert Y.shape == (100, 4)
        assert X.dtype == np.float32
        assert Y.dtype == np.float32

    def test_train_2_epochs(self, tmp_output_dir):
        from ml_surrogate.train import generate_synthetic_data, train

        X, Y = generate_synthetic_data(n_samples=100, seed=0)
        result = train(
            X,
            Y,
            epochs=2,
            batch_size=32,
            patience=100,  # Don't early-stop during smoke test.
            checkpoint_dir=str(tmp_output_dir / "surrogate_ckpt"),
            verbose=False,
        )
        assert result["epochs_trained"] == 2
        assert result["best_val_mse"] >= 0
        assert os.path.exists(result["checkpoint"])

    def test_save_and_load_synthetic_jsonl(self, tmp_output_dir):
        from ml_surrogate.train import save_synthetic_jsonl, load_data

        jsonl_path = tmp_output_dir / "synthetic.jsonl"
        save_synthetic_jsonl(str(jsonl_path), n_samples=50, seed=7)
        assert jsonl_path.exists()

        X, Y = load_data(str(jsonl_path))
        assert X.shape == (50, 69)
        assert Y.shape == (50, 4)

    def test_checkpoint_contents(self, tmp_output_dir):
        from ml_surrogate.train import generate_synthetic_data, train

        X, Y = generate_synthetic_data(n_samples=100, seed=0)
        result = train(
            X,
            Y,
            epochs=2,
            batch_size=32,
            patience=100,
            checkpoint_dir=str(tmp_output_dir / "ckpt_check"),
            verbose=False,
        )
        ckpt = torch.load(result["checkpoint"], weights_only=False)
        assert "model_state_dict" in ckpt
        assert "optimiser_state_dict" in ckpt
        assert "val_mse" in ckpt
        assert "x_mean" in ckpt
        assert "x_std" in ckpt
        assert "y_mean" in ckpt
        assert "y_std" in ckpt


@requires_torch
class TestUNetTraining:
    """Smoke test: run a few epochs of UNet repair training."""

    def test_generate_synthetic_layout_data(self):
        from ml_unet.train import generate_synthetic_layout_data

        images = generate_synthetic_layout_data(n_samples=10, seed=0)
        assert images.shape == (10, 5, 256, 256)
        assert images.dtype == np.float32
        # Images should have some non-zero rectangles.
        assert images.max() > 0

    def test_apply_random_mask(self):
        from ml_unet.train import apply_random_mask

        images = torch.rand(4, 5, 256, 256)
        masked, mask = apply_random_mask(images, mask_ratio=0.2, seed=42)
        assert masked.shape == images.shape
        assert mask.shape == (4, 1, 256, 256)
        # Mask should have some 1s and some 0s.
        assert mask.sum() > 0
        assert mask.sum() < mask.numel()
        # Masked regions should be zero.
        assert (masked * mask).sum() == 0

    def test_count_drc_violations(self):
        from ml_unet.train import count_drc_violations

        pred = torch.rand(2, 5, 64, 64)
        target = torch.rand(2, 5, 64, 64)
        mask = torch.ones(2, 1, 64, 64)
        n = count_drc_violations(pred, target, mask, error_threshold=0.15)
        assert isinstance(n, int)
        assert n >= 0

    def test_train_2_epochs(self, tmp_output_dir):
        from ml_unet.train import generate_synthetic_layout_data, train

        # Use very small images via a smaller dataset.
        images = generate_synthetic_layout_data(n_samples=10, seed=0)
        result = train(
            images,
            epochs=2,
            batch_size=4,
            patience=100,  # Don't early-stop during smoke test.
            checkpoint_dir=str(tmp_output_dir / "unet_ckpt"),
            verbose=False,
        )
        assert result["epochs_trained"] == 2
        assert result["best_val_drc_violations"] >= 0
        assert os.path.exists(result["checkpoint"])

    def test_checkpoint_contents(self, tmp_output_dir):
        from ml_unet.train import generate_synthetic_layout_data, train

        images = generate_synthetic_layout_data(n_samples=10, seed=0)
        result = train(
            images,
            epochs=2,
            batch_size=4,
            patience=100,
            checkpoint_dir=str(tmp_output_dir / "unet_ckpt_check"),
            verbose=False,
        )
        ckpt = torch.load(result["checkpoint"], weights_only=False)
        assert "model_state_dict" in ckpt
        assert "optimiser_state_dict" in ckpt
        assert "val_drc_violations" in ckpt
        assert "val_loss" in ckpt
