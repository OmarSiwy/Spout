from __future__ import annotations

import importlib

import pytest


def _require_torch_stack() -> tuple[object, object]:
    torch = pytest.importorskip("torch")
    pytest.importorskip("numpy")
    return torch, pytest


def test_python_package_imports() -> None:
    pytest.importorskip("numpy")
    importlib.import_module("spout")
    importlib.import_module("spout.visualizer")


def test_surrogate_forward_shape() -> None:
    torch, _ = _require_torch_stack()
    from spout.surrogate.model import build_model

    model = build_model()
    y = model(torch.randn(4, 69))
    assert y.shape == (4, 4)


def test_constraint_forward_shape() -> None:
    torch, _ = _require_torch_stack()
    pytest.importorskip("torch_geometric")
    from spout.constraint.model import DEVICE_FEAT_DIM, build_model

    model = build_model()
    embeddings = model(torch.randn(8, DEVICE_FEAT_DIM), torch.randint(0, 8, (2, 24)))
    assert embeddings.shape[0] == 8


def test_gcnrl_forward_shape() -> None:
    torch, _ = _require_torch_stack()
    pytest.importorskip("torch_geometric")
    from spout.gcnrl.model import NODE_FEAT_DIM, NUM_ACTIONS, build_model

    model = build_model()
    logits, values = model(
        torch.randn(10, NODE_FEAT_DIM),
        torch.randint(0, 10, (2, 30)),
        torch.zeros(10, dtype=torch.long),
        torch.tensor([0]),
    )
    assert logits.shape == (1, NUM_ACTIONS)
    assert values.shape == (1, 1)


def test_unet_forward_shape() -> None:
    torch, _ = _require_torch_stack()
    from spout.unet.model import IN_CHANNELS, build_model

    model = build_model(base_features=8)
    out = model(torch.randn(1, IN_CHANNELS, 64, 64))
    assert out.shape == (1, 1, 64, 64)
