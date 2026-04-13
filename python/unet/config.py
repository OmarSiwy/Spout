"""Configuration defaults for the UNet model package."""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path

from ..config import UnetTrainConfig as _RootUnetTrainConfig

CHECKPOINT_DIR = Path("checkpoints/unet")
RL_CHECKPOINT_DIR = CHECKPOINT_DIR / "rl"


@dataclass(slots=True)
class UnetTrainConfig(_RootUnetTrainConfig):
    """Module-local alias for UNet training defaults."""


def default_checkpoint_dir() -> Path:
    """Return the default checkpoint directory for UNet training."""
    return CHECKPOINT_DIR
