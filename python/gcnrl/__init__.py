"""GCN-RL placement package for python_refactor."""

from __future__ import annotations

import importlib as _importlib


def __getattr__(name):
    exports = {
        'GCNActorCritic': '.model',
        'GraphTransformerActorCritic': '.model',
        'build_model': '.model',
        'build_transformer_model': '.model',
        'train': '.train',
        'train_transformer': '.train',
        'transfer_gcn_to_transformer': '.train',
        'PlacementEnv': '.train',
        'CurriculumStage': '..utility.transformer_training',
        'CurriculumSchedule': '..utility.transformer_training',
    }
    if name in exports:
        mod = _importlib.import_module(exports[name], __package__)
        return getattr(mod, name)
    raise AttributeError(f'module {__name__!r} has no attribute {name!r}')


__all__ = [
    'GCNActorCritic',
    'GraphTransformerActorCritic',
    'build_model',
    'build_transformer_model',
    'train',
    'train_transformer',
    'transfer_gcn_to_transformer',
    'PlacementEnv',
    'CurriculumStage',
    'CurriculumSchedule',
]
