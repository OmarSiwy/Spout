"""Configuration defaults for the GCN-RL model package."""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path

from ..config import GcnrlTrainConfig as _RootGcnrlTrainConfig

CHECKPOINT_DIR = Path("checkpoints/gcnrl")
TRANSFORMER_CHECKPOINT_DIR = Path("checkpoints/transformer")


@dataclass(slots=True)
class GcnrlTrainConfig(_RootGcnrlTrainConfig):
    """Module-local alias for GCN-RL training defaults."""


def default_checkpoint_dir() -> Path:
    """Return the default checkpoint directory for actor-critic training."""
    return CHECKPOINT_DIR
