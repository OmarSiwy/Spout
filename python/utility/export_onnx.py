#!/usr/bin/env python3
"""Unified ONNX exporter for the refactored ML modules."""

from __future__ import annotations

import sys
from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parent.parent
if str(PROJECT_ROOT) not in sys.path:
    sys.path.insert(0, str(PROJECT_ROOT))

import argparse
import json
import logging
from typing import Callable

import torch
import torch.nn as nn

from python.constraint.model import DEVICE_FEAT_DIM as CONSTRAINT_FEAT_DIM, build_model as build_constraint_model
from python.gcnrl.model import NODE_FEAT_DIM as GCNRL_NODE_FEAT_DIM, build_model as build_gcnrl_model
from python.surrogate.model import build_model as build_surrogate_model
from python.unet.model import IMG_SIZE, IN_CHANNELS, build_model as build_unet_model

logger = logging.getLogger(__name__)
PROJECT_ROOT = Path(__file__).resolve().parent.parent
CHECKPOINTS = PROJECT_ROOT / "checkpoints"


class ConstraintWrapper(nn.Module):
    def __init__(self, model: nn.Module) -> None:
        super().__init__()
        self.model = model

    def forward(self, x: torch.Tensor, edge_index: torch.Tensor) -> torch.Tensor:
        return self.model(x, edge_index)


class GcnrlWrapper(nn.Module):
    def __init__(self, model: nn.Module) -> None:
        super().__init__()
        self.model = model

    def forward(
        self,
        x: torch.Tensor,
        edge_index: torch.Tensor,
        batch: torch.Tensor,
        current_device_idx: torch.Tensor,
    ) -> tuple[torch.Tensor, torch.Tensor]:
        return self.model(x, edge_index, batch, current_device_idx)


ExportFn = Callable[[Path, Path, int], Path]


def _load_checkpoint(model: nn.Module, checkpoint_path: Path) -> nn.Module:
    checkpoint = torch.load(checkpoint_path, map_location="cpu", weights_only=False)
    state_dict = checkpoint.get("model_state_dict", checkpoint)
    model.load_state_dict(state_dict)
    return model.eval()


def export_surrogate(checkpoint_path: Path, output_path: Path, opset: int) -> Path:
    model = _load_checkpoint(build_surrogate_model(), checkpoint_path)
    dummy = torch.randn(1, 69)
    torch.onnx.export(
        model,
        dummy,
        str(output_path),
        opset_version=opset,
        input_names=["placement_features"],
        output_names=["cost_predictions"],
        dynamic_axes={"placement_features": {0: "batch_size"}, "cost_predictions": {0: "batch_size"}},
    )
    return output_path


def export_constraint(checkpoint_path: Path, output_path: Path, opset: int) -> Path:
    model = ConstraintWrapper(_load_checkpoint(build_constraint_model(), checkpoint_path))
    dummy_x = torch.randn(30, CONSTRAINT_FEAT_DIM)
    dummy_edge_index = torch.randint(0, 30, (2, 90))
    torch.onnx.export(
        model,
        (dummy_x, dummy_edge_index),
        str(output_path),
        opset_version=opset,
        input_names=["node_features", "edge_index"],
        output_names=["embeddings"],
        dynamic_axes={"node_features": {0: "num_nodes"}, "edge_index": {1: "num_edges"}, "embeddings": {0: "num_nodes"}},
    )
    return output_path


def export_gcnrl(checkpoint_path: Path, output_path: Path, opset: int) -> Path:
    model = GcnrlWrapper(_load_checkpoint(build_gcnrl_model(), checkpoint_path))
    dummy_x = torch.randn(20, GCNRL_NODE_FEAT_DIM)
    dummy_edge_index = torch.randint(0, 20, (2, 60))
    dummy_batch = torch.zeros(20, dtype=torch.long)
    dummy_current_idx = torch.tensor([0], dtype=torch.long)
    torch.onnx.export(
        model,
        (dummy_x, dummy_edge_index, dummy_batch, dummy_current_idx),
        str(output_path),
        opset_version=opset,
        input_names=["node_features", "edge_index", "batch", "current_device_idx"],
        output_names=["action_logits", "state_value"],
        dynamic_axes={
            "node_features": {0: "num_nodes"},
            "edge_index": {1: "num_edges"},
            "batch": {0: "num_nodes"},
            "action_logits": {0: "batch_size"},
            "state_value": {0: "batch_size"},
        },
    )
    return output_path


def export_unet(checkpoint_path: Path, output_path: Path, opset: int) -> Path:
    model = _load_checkpoint(build_unet_model(), checkpoint_path)
    dummy = torch.randn(1, IN_CHANNELS, IMG_SIZE, IMG_SIZE)
    torch.onnx.export(
        model,
        dummy,
        str(output_path),
        opset_version=opset,
        input_names=["layout_image"],
        output_names=["violation_heatmap"],
        dynamic_axes={"layout_image": {0: "batch_size"}, "violation_heatmap": {0: "batch_size"}},
    )
    return output_path


SPECS: dict[str, tuple[Path, str, ExportFn]] = {
    "surrogate": (CHECKPOINTS / "surrogate" / "best_model.pt", "surrogate_cost.onnx", export_surrogate),
    "constraint": (CHECKPOINTS / "constraint" / "best_model.pt", "constraint_sage.onnx", export_constraint),
    "gcnrl": (CHECKPOINTS / "gcnrl" / "best_model.pt", "gcnrl_actor_critic.onnx", export_gcnrl),
    "unet": (CHECKPOINTS / "unet" / "best_model.pt", "unet_drc_heatmap.onnx", export_unet),
}


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Export refactored ML models to ONNX.")
    parser.add_argument("model", choices=("all", *SPECS.keys()))
    parser.add_argument("--checkpoint", type=Path)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--output-dir", type=Path)
    parser.add_argument("--opset", type=int, default=17)
    return parser


def export_one(model_key: str, checkpoint: Path | None, output: Path | None, output_dir: Path | None, opset: int) -> Path:
    default_checkpoint, default_name, exporter = SPECS[model_key]
    checkpoint_path = checkpoint or default_checkpoint
    destination_dir = output_dir or checkpoint_path.parent
    destination_dir.mkdir(parents=True, exist_ok=True)
    output_path = output or destination_dir / default_name
    exported = exporter(checkpoint_path, output_path, opset)
    logger.info("exported %s -> %s", model_key, exported)
    if model_key == "surrogate":
        ckpt = torch.load(checkpoint_path, map_location="cpu", weights_only=False)
        stats_path = exported.with_suffix(".stats.json")
        stats = {k: ckpt.get(k) for k in ("x_mean", "x_std", "y_mean", "y_std")}
        with stats_path.open("w") as handle:
            json.dump(stats, handle, indent=2)
        logger.info("wrote surrogate normalization stats -> %s", stats_path)
    return exported


def main() -> None:
    logging.basicConfig(level=logging.INFO, format="%(levelname)s: %(message)s")
    args = build_parser().parse_args()
    if args.model == "all":
        for model_key in SPECS:
            export_one(model_key, None, None, args.output_dir, args.opset)
        return
    export_one(args.model, args.checkpoint, args.output, args.output_dir, args.opset)


if __name__ == "__main__":
    main()
