# python_refactor

Parallel Python surface for Spout.

## Goals
- Keep the original `python/` code untouched.
- Make `python_refactor/` self-supporting on its own imports and entrypoints.
- Keep per-model structure consistent: `config.py`, `model.py`, `train.py`, `README.md`.
- Move reusable logic into `python_refactor/utility/`.
- Keep model comments focused on essential model steps; optimization notes are justified separately.

## Layout
- `config.py` — shared runtime and training configuration.
- `ffi.py` — Zig/ctypes bridge.
- `inference.py` — pipeline / inference orchestration.
- `train.py` — top-level training dispatcher.
- `visualizer.py` — training and evaluation visualization helpers.
- `utility/` — reusable helpers shared across model families.
- `ml_*` — self-contained model packages with `config.py`, `model.py`, and `train.py`.

## Current migration rules
- Do not delete or rewrite the legacy `python/` tree.
- `benchmark` and `auto_train` live in `tools/`.
- ONNX export is unified under `tools/export_onnx.py`.
- Extra logic from legacy sidecars such as graph-transformer / RL-repair helpers belongs in `utility/` when it can be generalized.
