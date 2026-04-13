#!/usr/bin/env python3
"""Autoresearch loop runner for Spout2 ML modules.

Karpathy-style train -> measure -> adjust -> repeat cycle.  For each ML
module the script:
  1. Runs training with the current hyperparameter configuration.
  2. Parses the primary metric from the training output (stdout/stderr).
  3. Picks the next hyperparameter to try (coordinate-descent random
     perturbation within the defined search space).
  4. Keeps the change if the metric improved; reverts otherwise.
  5. Stops after ``--patience`` consecutive non-improvements or
     ``--max-iters`` total iterations.

Results are logged to ``output/autotrain_{module}_{timestamp}.jsonl``.

Usage:
    PYTHONPATH=python python tools/autotrain.py --module surrogate --max-iters 10
    PYTHONPATH=python python tools/autotrain.py --module all --max-iters 5 --epochs 20
"""

from __future__ import annotations

import argparse
import copy
import json
import logging
import math
import os
import re
import subprocess
import sys
import time
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path
from typing import Any, Sequence

# ---------------------------------------------------------------------------
# Project paths (mirrors benchmark_runner.py pattern)
# ---------------------------------------------------------------------------

PROJECT_ROOT = Path(__file__).resolve().parent.parent
_python_dir = str(PROJECT_ROOT / "python")
if _python_dir not in sys.path:
    sys.path.insert(0, _python_dir)

OUTPUT_DIR = PROJECT_ROOT / "output"

logger = logging.getLogger("autotrain")


# ═══════════════════════════════════════════════════════════════════════════
# Search-space definitions (derived from each module's autoresearch.md)
# ═══════════════════════════════════════════════════════════════════════════

@dataclass
class HParam:
    """Single hyperparameter description."""
    name: str
    # For categorical / discrete choices supply ``choices``.
    # For continuous ranges supply ``lo`` / ``hi``.
    choices: list[Any] | None = None
    lo: float | None = None
    hi: float | None = None
    default: Any = None
    log_scale: bool = False          # sample in log space (for lr etc.)
    cli_flag: str | None = None      # override: CLI flag name (--foo-bar)
    is_int: bool = False             # round to int after perturbation

    @property
    def flag(self) -> str:
        if self.cli_flag is not None:
            return self.cli_flag
        return "--" + self.name.replace("_", "-")


@dataclass
class ModuleSpec:
    """Everything autotrain needs to know about one ML module."""
    key: str                          # short name (e.g. "surrogate")
    directory: str                    # relative to PROJECT_ROOT/python
    cli: str                          # python -m invocation
    metric_name: str                  # human label
    metric_regex: str                 # regex with a single capturing group
    metric_transform: str             # "raw" | "one_minus"
    improvement_pct: float            # stop when improvement < this %
    hparams: list[HParam] = field(default_factory=list)
    extra_cli_flags: dict[str, str] = field(default_factory=dict)

    def parse_metric(self, output: str) -> float | None:
        """Extract the primary metric from training output text."""
        m = re.search(self.metric_regex, output)
        if m is None:
            return None
        raw = float(m.group(1))
        if self.metric_transform == "one_minus":
            return 1.0 - raw
        return raw


# ---------------------------------------------------------------------------
# Per-module specs
# ---------------------------------------------------------------------------

SURROGATE = ModuleSpec(
    key="surrogate",
    directory="python/surrogate",
    cli="surrogate.train",
    metric_name="Validation MSE",
    metric_regex=r"Best val MSE:\s*([\d.eE+-]+)",
    metric_transform="raw",
    improvement_pct=1.0,
    hparams=[
        HParam("batch_size", choices=[32, 64, 128, 256], default=64, cli_flag="--batch-size"),
        HParam("lr", lo=1e-4, hi=1e-2, default=1e-3, log_scale=True),
    ],
)

PARAGRAPH = ModuleSpec(
    key="paragraph",
    directory="python/ml_paragraph",
    cli="ml_paragraph.train",
    metric_name="1 - R^2",
    metric_regex=r"Best val R\^2:\s*([\d.eE+-]+)",
    metric_transform="one_minus",
    improvement_pct=1.0,
    hparams=[
        HParam("n_graphs", lo=200, hi=2000, default=200, is_int=True, cli_flag="--n-graphs"),
        HParam("lr", lo=1e-4, hi=1e-2, default=1e-3, log_scale=True),
    ],
)

CONSTRAINT = ModuleSpec(
    key="constraint",
    directory="python/constraint",
    cli="constraint.train",
    metric_name="1 - F1",
    metric_regex=r"Best val F1:\s*([\d.eE+-]+)",
    metric_transform="one_minus",
    improvement_pct=1.0,
    hparams=[
        HParam("n_graphs", lo=200, hi=2000, default=200, is_int=True, cli_flag="--n-graphs"),
        HParam("lr", lo=1e-4, hi=1e-2, default=1e-3, log_scale=True),
        HParam("temperature", lo=0.03, hi=0.2, default=0.07),
    ],
)

UNET = ModuleSpec(
    key="unet",
    directory="python/unet",
    cli="unet.train",
    metric_name="DRC violations",
    metric_regex=r"Best DRC violations:\s*(\d+)",
    metric_transform="raw",
    improvement_pct=5.0,
    hparams=[
        HParam("batch_size", choices=[4, 8, 16], default=8, cli_flag="--batch-size"),
        HParam("lr", lo=1e-4, hi=1e-2, default=1e-3, log_scale=True),
        HParam("mask_ratio", lo=0.1, hi=0.4, default=0.2, cli_flag="--mask-ratio"),
        HParam("n_samples", lo=200, hi=2000, default=500, is_int=True, cli_flag="--n-samples"),
    ],
)

GCNRL = ModuleSpec(
    key="gcnrl",
    directory="python/gcnrl",
    cli="gcnrl.train",
    metric_name="Placement cost",
    metric_regex=r"Best placement cost:\s*([\d.eE+-]+)",
    metric_transform="raw",
    improvement_pct=5.0,
    hparams=[
        HParam("lr", lo=1e-4, hi=1e-3, default=3e-4, log_scale=True),
        HParam("clip_eps", lo=0.1, hi=0.3, default=0.2, cli_flag="--clip-eps"),
        HParam("update_every", choices=[5, 10, 20], default=10, cli_flag="--update-every"),
        HParam("n_episodes", lo=500, hi=5000, default=500, is_int=True, cli_flag="--n-episodes"),
    ],
)

ALL_MODULES: dict[str, ModuleSpec] = {
    s.key: s for s in [SURROGATE, PARAGRAPH, CONSTRAINT, UNET, GCNRL]
}


# ═══════════════════════════════════════════════════════════════════════════
# Hyperparameter sampling helpers
# ═══════════════════════════════════════════════════════════════════════════

import random as _random


def _perturb_value(hp: HParam, current: Any, rng: _random.Random) -> Any:
    """Return a new candidate value for *hp* by perturbing *current*."""
    if hp.choices is not None:
        # Categorical: pick a random different choice.
        candidates = [c for c in hp.choices if c != current]
        if not candidates:
            return current
        return rng.choice(candidates)

    # Continuous / integer range.
    assert hp.lo is not None and hp.hi is not None
    if hp.log_scale:
        log_lo, log_hi = math.log(hp.lo), math.log(hp.hi)
        log_cur = math.log(max(current, hp.lo))
        scale = (log_hi - log_lo) * 0.3
        new_log = log_cur + rng.gauss(0, scale)
        new_log = max(log_lo, min(log_hi, new_log))
        val = math.exp(new_log)
    else:
        scale = (hp.hi - hp.lo) * 0.3
        val = current + rng.gauss(0, scale)
        val = max(hp.lo, min(hp.hi, val))

    if hp.is_int:
        val = int(round(val))
    return val


def _defaults(spec: ModuleSpec) -> dict[str, Any]:
    """Return a dict of default hyperparameter values."""
    return {hp.name: hp.default for hp in spec.hparams}


# ═══════════════════════════════════════════════════════════════════════════
# Training subprocess
# ═══════════════════════════════════════════════════════════════════════════

def _build_cmd(
    spec: ModuleSpec,
    hparams: dict[str, Any],
    *,
    epochs: int | None = None,
) -> list[str]:
    """Build the subprocess command list."""
    cmd = [sys.executable, "-m", spec.cli]

    # epochs / n-episodes override
    if epochs is not None:
        if spec.key == "gcnrl":
            cmd += ["--n-episodes", str(epochs)]
        else:
            cmd += ["--epochs", str(epochs)]

    for hp in spec.hparams:
        val = hparams.get(hp.name)
        if val is None:
            continue
        # Skip n_episodes if already set via epochs override
        if spec.key == "gcnrl" and hp.name == "n_episodes" and epochs is not None:
            continue
        cmd += [hp.flag, str(val)]

    return cmd


def run_training(
    spec: ModuleSpec,
    hparams: dict[str, Any],
    *,
    epochs: int | None = None,
    timeout: int = 3600,
) -> tuple[float | None, str]:
    """Run one training iteration and return (metric, full_output).

    Returns (None, output) if the metric could not be parsed.
    """
    cmd = _build_cmd(spec, hparams, epochs=epochs)
    env = os.environ.copy()
    # Ensure python/ is on PYTHONPATH so ``python -m surrogate.train`` works.
    python_dir = str(PROJECT_ROOT / "python")
    existing = env.get("PYTHONPATH", "")
    if python_dir not in existing:
        env["PYTHONPATH"] = python_dir + (":" + existing if existing else "")

    logger.info("Running: %s", " ".join(cmd))

    try:
        proc = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=timeout,
            cwd=str(PROJECT_ROOT),
            env=env,
        )
    except subprocess.TimeoutExpired:
        return None, "[TIMEOUT]"
    except FileNotFoundError as exc:
        return None, f"[ERROR] {exc}"

    full_output = proc.stdout + "\n" + proc.stderr
    metric = spec.parse_metric(full_output)
    return metric, full_output


# ═══════════════════════════════════════════════════════════════════════════
# Main optimisation loop
# ═══════════════════════════════════════════════════════════════════════════

def autotrain_module(
    spec: ModuleSpec,
    *,
    max_iters: int = 10,
    patience: int = 3,
    epochs: int | None = None,
    seed: int = 42,
) -> list[dict[str, Any]]:
    """Run the autoresearch loop for a single module.

    Returns a list of per-iteration records (also written to JSONL).
    """
    rng = _random.Random(seed)
    current_hparams = _defaults(spec)
    best_metric: float | None = None
    no_improve = 0
    records: list[dict[str, Any]] = []

    # Prepare output log
    timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    log_path = OUTPUT_DIR / f"autotrain_{spec.key}_{timestamp}.jsonl"

    print(f"\n{'=' * 70}")
    print(f"  AUTOTRAIN: {spec.key.upper()}")
    print(f"  Metric: {spec.metric_name} (lower is better)")
    print(f"  Max iters: {max_iters} | Patience: {patience}")
    print(f"  Log: {log_path}")
    print(f"{'=' * 70}\n")

    for iteration in range(1, max_iters + 1):
        # --- propose candidate ---
        if iteration == 1:
            candidate = copy.deepcopy(current_hparams)
        else:
            # Coordinate descent: perturb one random hyperparameter.
            candidate = copy.deepcopy(current_hparams)
            hp = rng.choice(spec.hparams)
            old_val = candidate[hp.name]
            new_val = _perturb_value(hp, old_val, rng)
            candidate[hp.name] = new_val
            logger.info(
                "Iter %d: perturbing %s: %s -> %s",
                iteration, hp.name, old_val, new_val,
            )

        # --- run training ---
        t0 = time.time()
        metric, output = run_training(spec, candidate, epochs=epochs)
        elapsed = time.time() - t0

        # --- record ---
        record: dict[str, Any] = {
            "iteration": iteration,
            "hparams": copy.deepcopy(candidate),
            "metric": metric,
            "metric_name": spec.metric_name,
            "elapsed_s": round(elapsed, 1),
            "improved": False,
        }

        if metric is None:
            logger.warning(
                "Iter %d: could not parse metric from output. "
                "Reverting to previous config.",
                iteration,
            )
            # Dump the last 30 lines of output for debugging.
            tail = "\n".join(output.strip().splitlines()[-30:])
            logger.warning("Last 30 lines of output:\n%s", tail)
            no_improve += 1
            record["error"] = "metric_parse_failed"
        elif best_metric is None or metric < best_metric:
            improvement_pct = (
                0.0
                if best_metric is None
                else (best_metric - metric) / max(abs(best_metric), 1e-12) * 100
            )
            if best_metric is not None and improvement_pct < spec.improvement_pct:
                logger.info(
                    "Iter %d: metric=%.6f (improvement %.2f%% < %.1f%% threshold). "
                    "Not counted as improvement.",
                    iteration, metric, improvement_pct, spec.improvement_pct,
                )
                no_improve += 1
            else:
                logger.info(
                    "Iter %d: metric=%.6f -- NEW BEST (prev=%s, improvement=%.2f%%)",
                    iteration,
                    metric,
                    f"{best_metric:.6f}" if best_metric is not None else "N/A",
                    improvement_pct,
                )
                best_metric = metric
                current_hparams = copy.deepcopy(candidate)
                no_improve = 0
                record["improved"] = True
        else:
            logger.info(
                "Iter %d: metric=%.6f (no improvement over best=%.6f). Reverting.",
                iteration, metric, best_metric,
            )
            no_improve += 1

        record["best_metric"] = best_metric
        record["no_improve_streak"] = no_improve
        records.append(record)

        # Write incrementally
        with open(log_path, "a") as f:
            f.write(json.dumps(record, default=str) + "\n")

        # --- early stopping ---
        if no_improve >= patience:
            logger.info(
                "Stopping early: %d consecutive non-improvements (patience=%d).",
                no_improve, patience,
            )
            break

    return records


# ═══════════════════════════════════════════════════════════════════════════
# Summary table
# ═══════════════════════════════════════════════════════════════════════════

def print_summary(
    spec: ModuleSpec,
    records: list[dict[str, Any]],
) -> None:
    """Print a compact summary table for one module's run."""
    print(f"\n{'─' * 80}")
    print(f"  Summary: {spec.key.upper()}  |  Metric: {spec.metric_name}")
    print(f"{'─' * 80}")
    print(
        f"  {'Iter':>4}  {'Metric':>12}  {'Best':>12}  "
        f"{'Improved':>8}  {'Time':>7}  Hyperparams"
    )
    print(f"  {'─' * 4}  {'─' * 12}  {'─' * 12}  {'─' * 8}  {'─' * 7}  {'─' * 30}")

    for r in records:
        m = r["metric"]
        m_str = f"{m:.6f}" if m is not None else "FAILED"
        b = r.get("best_metric")
        b_str = f"{b:.6f}" if b is not None else "N/A"
        imp = "YES" if r.get("improved") else "no"
        t_str = f"{r['elapsed_s']:.1f}s"

        # Compact hparams display.
        hp_parts = []
        for k, v in r["hparams"].items():
            if isinstance(v, float):
                hp_parts.append(f"{k}={v:.4g}")
            else:
                hp_parts.append(f"{k}={v}")
        hp_str = ", ".join(hp_parts)

        print(f"  {r['iteration']:>4}  {m_str:>12}  {b_str:>12}  {imp:>8}  {t_str:>7}  {hp_str}")

    # Final best config.
    best_records = [r for r in records if r.get("improved")]
    if best_records:
        best = best_records[-1]
        print(f"\n  Best metric: {best['best_metric']:.6f}")
        print(f"  Best config: {best['hparams']}")
    elif records and records[0].get("best_metric") is not None:
        print(f"\n  Best metric: {records[0]['best_metric']:.6f}")
        print(f"  Best config: {records[0]['hparams']}")
    else:
        print("\n  No successful training runs.")

    print(f"{'─' * 80}\n")


# ═══════════════════════════════════════════════════════════════════════════
# CLI
# ═══════════════════════════════════════════════════════════════════════════

def main() -> None:
    parser = argparse.ArgumentParser(
        description="Autoresearch loop runner for Spout2 ML modules.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    parser.add_argument(
        "--module",
        choices=list(ALL_MODULES.keys()) + ["all"],
        required=True,
        help="Which module(s) to optimise.",
    )
    parser.add_argument(
        "--max-iters",
        type=int,
        default=10,
        help="Maximum number of optimisation iterations per module (default: 10).",
    )
    parser.add_argument(
        "--patience",
        type=int,
        default=3,
        help="Stop after N consecutive non-improvements (default: 3).",
    )
    parser.add_argument(
        "--epochs",
        type=int,
        default=None,
        help="Override training epochs (or n-episodes for gcnrl).",
    )
    parser.add_argument(
        "--seed",
        type=int,
        default=42,
        help="Random seed for hyperparameter perturbation (default: 42).",
    )
    parser.add_argument(
        "--timeout",
        type=int,
        default=3600,
        help="Max seconds per training run (default: 3600).",
    )
    parser.add_argument(
        "-v", "--verbose",
        action="store_true",
        help="Enable debug logging.",
    )

    args = parser.parse_args()

    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
    )

    if args.module == "all":
        modules = list(ALL_MODULES.values())
    else:
        modules = [ALL_MODULES[args.module]]

    all_results: dict[str, list[dict[str, Any]]] = {}

    for spec in modules:
        records = autotrain_module(
            spec,
            max_iters=args.max_iters,
            patience=args.patience,
            epochs=args.epochs,
            seed=args.seed,
        )
        all_results[spec.key] = records
        print_summary(spec, records)

    # Grand summary if multiple modules were run.
    if len(modules) > 1:
        print(f"\n{'=' * 80}")
        print("  GRAND SUMMARY")
        print(f"{'=' * 80}")
        print(f"  {'Module':<15} {'Best Metric':>15} {'Iters':>6} {'Metric Name':<25}")
        print(f"  {'─' * 15} {'─' * 15} {'─' * 6} {'─' * 25}")
        for spec in modules:
            records = all_results[spec.key]
            best = None
            for r in records:
                if r.get("best_metric") is not None:
                    best = r["best_metric"]
            best_str = f"{best:.6f}" if best is not None else "N/A"
            print(
                f"  {spec.key:<15} {best_str:>15} {len(records):>6} {spec.metric_name:<25}"
            )
        print(f"{'=' * 80}\n")


if __name__ == "__main__":
    main()
