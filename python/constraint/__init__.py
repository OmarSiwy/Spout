"""Refactored constraint-prediction package."""

import importlib as _importlib


def __getattr__(name):
    exports = {
        "ConstraintGraphSAGE": ".model",
        "EdgeDecoder": ".model",
        "build_model": ".model",
        "predict_constraints": ".model",
        "train": ".train",
        "generate_synthetic_constraint_data": ".train",
        "generate_synthetic_data": ".train",
        "generate_synthetic_dataset": ".train",
        "load_or_generate_dataset": ".train",
        "compute_f1": ".train",
        "PairClassifier": ".train",
        "evaluate_with_learned_threshold": ".train",
        "ConstraintTrainConfig": ".config",
    }
    if name in exports:
        mod = _importlib.import_module(exports[name], __package__)
        return getattr(mod, name)
    raise AttributeError(f"module {__name__!r} has no attribute {name!r}")


__all__ = list({
    "ConstraintGraphSAGE",
    "EdgeDecoder",
    "build_model",
    "predict_constraints",
    "train",
    "generate_synthetic_constraint_data",
    "generate_synthetic_data",
    "generate_synthetic_dataset",
    "load_or_generate_dataset",
    "compute_f1",
    "PairClassifier",
    "evaluate_with_learned_threshold",
    "ConstraintTrainConfig",
})
