"""UNet repair package for python_refactor."""

from __future__ import annotations

import importlib as _importlib


def __getattr__(name):
    exports = {
        'UNetRepair': '.model',
        'DRCRepairUNet': '.model',
        'FiLMLayer': '.model',
        'GraphConditioner': '.model',
        'build_model': '.model',
        'train': '.train',
        'generate_drc_training_data': '.train',
        'predict_repair': '.train',
        'predict_with_tta': '.train',
        'DRCRepairPolicy': '.train',
        'DRCRepairEnv': '.train',
        'train_rl_repair': '.train',
        'predict_rl_repair': '.train',
    }
    if name in exports:
        mod = _importlib.import_module(exports[name], __package__)
        return getattr(mod, name)
    raise AttributeError(f'module {__name__!r} has no attribute {name!r}')


__all__ = [
    'UNetRepair',
    'DRCRepairUNet',
    'FiLMLayer',
    'GraphConditioner',
    'build_model',
    'train',
    'generate_drc_training_data',
    'predict_repair',
    'predict_with_tta',
    'DRCRepairPolicy',
    'DRCRepairEnv',
    'train_rl_repair',
    'predict_rl_repair',
]
