"""Surrogate Cost MLP package for python_refactor."""

from __future__ import annotations

import importlib as _importlib


def __getattr__(name):
    exports = {
        'SurrogateCostMLP': '.model',
        'SurrogateEnsemble': '.model',
        'build_model': '.model',
        'build_ensemble': '.model',
        'train': '.train',
        'train_ensemble': '.train',
        'load_data': '.train',
        'generate_synthetic_data': '.train',
        'save_synthetic_jsonl': '.train',
    }
    if name in exports:
        mod = _importlib.import_module(exports[name], __package__)
        return getattr(mod, name)
    raise AttributeError(f'module {__name__!r} has no attribute {name!r}')


__all__ = [
    'SurrogateCostMLP',
    'SurrogateEnsemble',
    'build_model',
    'build_ensemble',
    'train',
    'train_ensemble',
    'load_data',
    'generate_synthetic_data',
    'save_synthetic_jsonl',
]
