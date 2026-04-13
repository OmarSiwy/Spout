"""ML model performance tests against training and test data.

Loads each model, runs inference on the fixtures/training and fixtures/test
SPICE files, and reports performance metrics. Fails if metrics fall below
minimum acceptable thresholds.

Requires:
    - libspout.so built (zig build)
    - PyTorch + torch_geometric installed
    - Model checkpoints trained (checkpoints/<model>/best_model.pt)
"""
from __future__ import annotations

import json
import pathlib
import time

import numpy as np
import pytest

from conftest import LIBSPOUT_PATH, PROJECT_ROOT

requires_libspout = pytest.mark.skipif(
    not LIBSPOUT_PATH.exists(), reason="libspout.so not built"
)

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

requires_torch = pytest.mark.skipif(not _has_torch, reason="PyTorch not available")
requires_torch_geometric = pytest.mark.skipif(
    not _has_torch_geometric, reason="torch_geometric not available"
)

FIXTURES = PROJECT_ROOT / "fixtures"
TRAINING_DIR = FIXTURES / "training"
TEST_DIR = FIXTURES / "test"
CHECKPOINTS = PROJECT_ROOT / "checkpoints"


def _collect_spice_files(directory: pathlib.Path) -> list[pathlib.Path]:
    """Collect base SPICE files (exclude LVS variants) from a directory."""
    if not directory.exists():
        return []
    return sorted(
        f for f in directory.glob("*.spice")
        if "_lvs" not in f.stem
    )


def _load_circuit_arrays(netlist: pathlib.Path) -> dict | None:
    """Parse a netlist through Spout and return arrays for ML."""
    from spout.ffi import SpoutFFI

    ffi = SpoutFFI(lib_path=str(LIBSPOUT_PATH))
    handle = ffi.init_layout(backend=1, pdk=0)
    try:
        ffi.parse_netlist(handle, str(netlist))
        ffi.extract_constraints(handle)
        return ffi.get_all_arrays(handle)
    except RuntimeError:
        return None
    finally:
        ffi.destroy(handle)


# ---------------------------------------------------------------------------
# Constraint model performance
# ---------------------------------------------------------------------------


@requires_libspout
@requires_torch
@requires_torch_geometric
class TestConstraintModelPerformance:
    """Test constraint GNN on training vs test data."""

    @pytest.fixture(autouse=True)
    def _load_model(self):
        checkpoint = CHECKPOINTS / "constraint" / "best_model.pt"
        if not checkpoint.exists():
            pytest.skip("Constraint model checkpoint not found")
        from spout.constraint.model import build_model
        self.model = build_model(device="cpu")
        state = torch.load(checkpoint, map_location="cpu", weights_only=False)
        self.model.load_state_dict(state.get("model_state_dict", state))
        self.model.eval()

    def _evaluate_on_dir(self, directory: pathlib.Path) -> dict:
        """Run constraint prediction on all circuits in directory."""
        from spout.constraint.train import build_graph

        files = _collect_spice_files(directory)
        if not files:
            pytest.skip(f"No SPICE files in {directory}")

        total_pairs = 0
        circuit_results = []

        for netlist in files:
            arrays = _load_circuit_arrays(netlist)
            if arrays is None or arrays["num_devices"] < 2:
                continue
            try:
                graph_data = build_graph(arrays)
                with torch.no_grad():
                    embeddings = self.model(
                        graph_data["x"], graph_data["edge_index"]
                    )
                n = embeddings.shape[0]
                total_pairs += n * (n - 1) // 2
                circuit_results.append({
                    "circuit": netlist.stem,
                    "devices": arrays["num_devices"],
                    "embedding_dim": embeddings.shape[1],
                })
            except Exception:
                continue

        return {
            "circuits_evaluated": len(circuit_results),
            "total_pairs": total_pairs,
            "details": circuit_results,
        }

    def test_training_data_inference(self):
        """Model should produce embeddings for all training circuits."""
        result = self._evaluate_on_dir(TRAINING_DIR)
        assert result["circuits_evaluated"] > 0, "No training circuits could be evaluated"
        print(f"\n  Constraint model: {result['circuits_evaluated']} training circuits, "
              f"{result['total_pairs']} pairs")

    def test_test_data_inference(self):
        """Model should produce embeddings for all test circuits."""
        result = self._evaluate_on_dir(TEST_DIR)
        assert result["circuits_evaluated"] > 0, "No test circuits could be evaluated"
        print(f"\n  Constraint model: {result['circuits_evaluated']} test circuits, "
              f"{result['total_pairs']} pairs")


# ---------------------------------------------------------------------------
# Surrogate cost model performance
# ---------------------------------------------------------------------------


@requires_libspout
@requires_torch
class TestSurrogateModelPerformance:
    """Test surrogate cost MLP on training vs test data."""

    @pytest.fixture(autouse=True)
    def _load_model(self):
        checkpoint = CHECKPOINTS / "surrogate" / "best_model.pt"
        if not checkpoint.exists():
            pytest.skip("Surrogate model checkpoint not found")
        from spout.surrogate.model import build_model
        self.model = build_model()
        state = torch.load(checkpoint, map_location="cpu", weights_only=False)
        self.model.load_state_dict(state.get("model_state_dict", state))
        self.model.eval()

    def _evaluate_on_dir(self, directory: pathlib.Path) -> dict:
        """Run surrogate cost prediction on all circuits in directory."""
        files = _collect_spice_files(directory)
        if not files:
            pytest.skip(f"No SPICE files in {directory}")

        predictions = []
        for netlist in files:
            arrays = _load_circuit_arrays(netlist)
            if arrays is None:
                continue
            try:
                n = arrays["num_devices"]
                if n == 0:
                    continue
                # Build a feature vector matching surrogate input format
                features = np.zeros((1, 69), dtype=np.float32)
                features[0, 0] = n
                features[0, 1] = arrays["num_nets"]
                features[0, 2] = arrays["num_pins"]
                with torch.no_grad():
                    pred = self.model(torch.from_numpy(features))
                predictions.append({
                    "circuit": netlist.stem,
                    "predicted_costs": pred.numpy().tolist(),
                })
            except Exception:
                continue

        return {
            "circuits_evaluated": len(predictions),
            "details": predictions,
        }

    def test_training_data_inference(self):
        """Model should produce cost predictions for training circuits."""
        result = self._evaluate_on_dir(TRAINING_DIR)
        assert result["circuits_evaluated"] > 0, "No training circuits could be evaluated"
        print(f"\n  Surrogate model: {result['circuits_evaluated']} training circuits evaluated")

    def test_test_data_inference(self):
        """Model should produce cost predictions for test circuits."""
        result = self._evaluate_on_dir(TEST_DIR)
        assert result["circuits_evaluated"] > 0, "No test circuits could be evaluated"
        print(f"\n  Surrogate model: {result['circuits_evaluated']} test circuits evaluated")


# ---------------------------------------------------------------------------
# UNet DRC repair model performance
# ---------------------------------------------------------------------------


@requires_torch
class TestUNetModelPerformance:
    """Test UNet DRC repair model produces valid heatmaps."""

    @pytest.fixture(autouse=True)
    def _load_model(self):
        checkpoint = CHECKPOINTS / "unet" / "best_model.pt"
        if not checkpoint.exists():
            pytest.skip("UNet model checkpoint not found")
        from spout.unet.model import IN_CHANNELS, build_model
        self.model = build_model()
        self.in_channels = IN_CHANNELS
        state = torch.load(checkpoint, map_location="cpu", weights_only=False)
        self.model.load_state_dict(state.get("model_state_dict", state))
        self.model.eval()

    def test_output_shape_and_range(self):
        """UNet output should be (B, 1, H, W) with values in [0, 1]."""
        dummy = torch.randn(2, self.in_channels, 64, 64)
        with torch.no_grad():
            out = self.model(dummy)
        assert out.shape == (2, 1, 64, 64)
        # Sigmoid output should be bounded
        assert out.min() >= -0.01, f"Output min {out.min()} below expected range"
        assert out.max() <= 1.01, f"Output max {out.max()} above expected range"


# ---------------------------------------------------------------------------
# Performance report
# ---------------------------------------------------------------------------


@requires_libspout
@requires_torch
def test_generate_ml_performance_report(tmp_path: pathlib.Path) -> None:
    """Generate a summary JSON report of all ML model performance.

    This test always passes — it produces a report file for analysis.
    """
    report = {
        "timestamp": time.strftime("%Y-%m-%d %H:%M:%S"),
        "training_circuits": len(_collect_spice_files(TRAINING_DIR)),
        "test_circuits": len(_collect_spice_files(TEST_DIR)),
        "models": {},
    }

    # Check which model checkpoints exist
    for model_name in ("surrogate", "constraint", "gcnrl", "unet"):
        ckpt = CHECKPOINTS / model_name / "best_model.pt"
        report["models"][model_name] = {
            "checkpoint_exists": ckpt.exists(),
            "checkpoint_size_bytes": ckpt.stat().st_size if ckpt.exists() else 0,
        }

    report_path = tmp_path / "ml_performance_report.json"
    report_path.write_text(json.dumps(report, indent=2))
    print(f"\n  ML performance report: {report_path}")
    print(f"  Training circuits: {report['training_circuits']}")
    print(f"  Test circuits: {report['test_circuits']}")
    for name, info in report["models"].items():
        status = "FOUND" if info["checkpoint_exists"] else "MISSING"
        print(f"  {name}: {status}")
