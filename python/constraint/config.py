"""Configuration defaults for the constraint model package."""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path

from ..config import ConstraintTrainConfig as _RootConstraintTrainConfig

CHECKPOINT_DIR = Path("checkpoints/constraint")


@dataclass(slots=True)
class ConstraintTrainConfig(_RootConstraintTrainConfig):
    """Module-local alias for constraint training defaults."""


def default_checkpoint_dir() -> Path:
    """Return the default checkpoint directory for constraint training."""
    return CHECKPOINT_DIR
