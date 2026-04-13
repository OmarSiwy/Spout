"""Configuration defaults for the surrogate model package."""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path

from ..config import SurrogateTrainConfig as _RootSurrogateTrainConfig

CHECKPOINT_DIR = Path("checkpoints/surrogate")


@dataclass(slots=True)
class SurrogateTrainConfig(_RootSurrogateTrainConfig):
    """Module-local alias for surrogate training defaults."""


def default_checkpoint_dir() -> Path:
    """Return the default checkpoint directory for surrogate training."""
    return CHECKPOINT_DIR
