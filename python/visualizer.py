"""Live training visualization for Spout ML models.

Saves PNG loss/metric curve plots at regular intervals during training and
optionally updates a live matplotlib window when a display is available.

Usage::

    from python_refactor.visualizer import TrainingVisualizer

    viz = TrainingVisualizer(
        model_name="surrogate",
        metrics=["train_loss", "val_mse"],
        output_dir="checkpoints/surrogate",
        save_every=10,
    )
    for epoch in range(1, epochs + 1):
        ...
        viz.update(epoch, {"train_loss": train_loss, "val_mse": val_mse})
    viz.finish()
"""

from __future__ import annotations

import os
import sys
from typing import Callable

# ---------------------------------------------------------------------------
# Graceful matplotlib import
# ---------------------------------------------------------------------------

try:
    import matplotlib
    # Use non-interactive backend unless a live display is explicitly requested;
    # this makes the module safe to import on headless training machines.
    if not os.environ.get("DISPLAY") and not os.environ.get("WAYLAND_DISPLAY"):
        matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    _MPL_AVAILABLE = True
except ImportError:
    _MPL_AVAILABLE = False

# ---------------------------------------------------------------------------
# Style selection
# ---------------------------------------------------------------------------

def _pick_style() -> None:
    """Apply a clean plot style, falling back gracefully."""
    if not _MPL_AVAILABLE:
        return
    for style in ("seaborn-v0_8-darkgrid", "seaborn-darkgrid", "ggplot"):
        try:
            plt.style.use(style)
            return
        except OSError:
            continue


_pick_style()


# ---------------------------------------------------------------------------
# Metric grouping helpers
# ---------------------------------------------------------------------------

_LOSS_KEYWORDS = ("loss", "mse", "mae", "nll", "cost")


def _is_loss_metric(name: str) -> bool:
    """Return True if the metric name looks like a loss (lower = better)."""
    lower = name.lower()
    return any(kw in lower for kw in _LOSS_KEYWORDS)


def _group_metrics(metrics: list[str]) -> tuple[list[str], list[str]]:
    """Split metric names into (loss_metrics, other_metrics)."""
    loss = [m for m in metrics if _is_loss_metric(m)]
    other = [m for m in metrics if not _is_loss_metric(m)]
    return loss, other


# ---------------------------------------------------------------------------
# TrainingVisualizer
# ---------------------------------------------------------------------------


class TrainingVisualizer:
    """Live training visualization — saves PNG plots + optional live matplotlib window.

    Args:
        model_name: Short name used in filenames (e.g. "surrogate", "unet").
        metrics: List of metric key names that will appear in ``update()`` dicts.
        output_dir: Directory where PNG files are written.
        save_every: Save a PNG snapshot every N calls to ``update()``.
        live: If True, attempt to show a live matplotlib window.  Requires a
            display and is silently disabled when one is not available.
        sample_fn: Optional ``callable(epoch) -> (fig, axes)`` for custom
            per-epoch sample visualizations.  When provided, its figure is
            saved alongside the curve plot.
        x_label: Label for the x-axis (default "epoch"; set to "episode" for RL).
    """

    def __init__(
        self,
        model_name: str,
        metrics: list[str],
        output_dir: str = ".",
        save_every: int = 5,
        live: bool = False,
        sample_fn: Callable | None = None,
        x_label: str = "epoch",
    ) -> None:
        self.model_name = model_name
        self.metrics = metrics
        self.output_dir = output_dir
        self.save_every = save_every
        self.live = live and _MPL_AVAILABLE and bool(
            os.environ.get("DISPLAY") or os.environ.get("WAYLAND_DISPLAY")
        )
        self.sample_fn = sample_fn
        self.x_label = x_label

        # History storage: {metric_name: [value, ...]}
        self.history: dict[str, list[float]] = {m: [] for m in metrics}
        self._steps: list[int] = []  # epoch/episode numbers

        # Best step tracking (per metric; for loss lower=better, else higher=better)
        self._best_step: dict[str, int] = {}
        self._best_val: dict[str, float] = {}
        for m in metrics:
            self._best_val[m] = float("inf") if _is_loss_metric(m) else float("-inf")
            self._best_step[m] = 1

        # Live window state
        self._fig = None
        self._axes = None
        self._call_count = 0

        # Ensure output directory exists
        import pathlib
        pathlib.Path(output_dir).mkdir(parents=True, exist_ok=True)

    # ------------------------------------------------------------------
    # Public API
    # ------------------------------------------------------------------

    def update(self, step: int, values: dict[str, float]) -> None:
        """Record metrics for this step and optionally update plots.

        Args:
            step: Current epoch or episode number (used as x-axis value).
            values: Dict mapping metric names to their current values.
                    Unknown keys are silently ignored.
        """
        self._call_count += 1
        self._steps.append(step)

        for m in self.metrics:
            v = values.get(m, float("nan"))
            self.history[m].append(v)
            # Update best tracking
            if not _is_nan(v):
                if _is_loss_metric(m) and v < self._best_val[m]:
                    self._best_val[m] = v
                    self._best_step[m] = step
                elif not _is_loss_metric(m) and v > self._best_val[m]:
                    self._best_val[m] = v
                    self._best_step[m] = step

        # Print compact one-line summary
        _print_summary(step, values, self._best_val)

        # Save PNG every `save_every` calls
        if self._call_count % self.save_every == 0:
            self._save_plots(step)

        # Update live window
        if self.live and _MPL_AVAILABLE:
            self._update_live(step)

    def finish(self) -> None:
        """Called at end of training. Saves final plots."""
        if self._steps:
            self._save_plots(self._steps[-1])
        if self.live and _MPL_AVAILABLE and self._fig is not None:
            try:
                plt.close(self._fig)
            except Exception:
                pass

    # ------------------------------------------------------------------
    # Internal helpers
    # ------------------------------------------------------------------

    def _build_figure(self, step: int):
        """Build and return a (fig, axes_list) for the current history."""
        loss_metrics, other_metrics = _group_metrics(self.metrics)

        n_rows = 0
        if loss_metrics:
            n_rows += 1
        if other_metrics:
            n_rows += 1
        if n_rows == 0:
            n_rows = 1

        fig, axes = plt.subplots(
            n_rows, 1,
            figsize=(10, 4 * n_rows),
            squeeze=False,
        )
        axes_flat = [ax for row in axes for ax in row]

        ax_idx = 0

        # --- Loss subplot ---
        if loss_metrics:
            ax = axes_flat[ax_idx]
            ax_idx += 1
            for m in loss_metrics:
                vals = self.history[m]
                if vals:
                    color = _metric_color(m)
                    ax.plot(self._steps, vals, label=m, color=color, linewidth=1.5)
                    # Mark best with a dotted vertical line
                    best_step = self._best_step.get(m)
                    if best_step is not None and best_step in self._steps:
                        ax.axvline(
                            x=best_step, color=color, linestyle=":",
                            alpha=0.6, linewidth=1.2,
                        )
            ax.set_ylabel("Loss")
            ax.set_xlabel(self.x_label.capitalize())
            ax.legend(loc="upper right", fontsize=8)
            ax.set_title(f"{self.model_name} — loss curves")

        # --- Other metrics subplot ---
        if other_metrics:
            ax = axes_flat[ax_idx]
            ax_idx += 1
            for m in other_metrics:
                vals = self.history[m]
                if vals:
                    color = _metric_color(m)
                    ax.plot(self._steps, vals, label=m, color=color, linewidth=1.5)
                    best_step = self._best_step.get(m)
                    if best_step is not None and best_step in self._steps:
                        ax.axvline(
                            x=best_step, color=color, linestyle=":",
                            alpha=0.6, linewidth=1.2,
                        )
            ax.set_ylabel("Metric value")
            ax.set_xlabel(self.x_label.capitalize())
            ax.legend(loc="lower right", fontsize=8)
            ax.set_title(f"{self.model_name} — metrics")

        # Global subtitle with current step
        fig.suptitle(
            f"{self.model_name}  |  {self.x_label}={step}",
            fontsize=10,
            y=1.01,
        )
        fig.tight_layout()
        return fig, axes_flat

    def _save_plots(self, step: int) -> None:
        """Save training curve PNGs to output_dir."""
        if not _MPL_AVAILABLE:
            return

        import pathlib

        out = pathlib.Path(self.output_dir)

        try:
            fig, _ = self._build_figure(step)

            # Numbered snapshot
            numbered = out / f"{self.model_name}_training_{self.x_label}{step:06d}.png"
            fig.savefig(str(numbered), dpi=150, bbox_inches="tight")

            # Overwrite "latest" for easy monitoring
            latest = out / f"{self.model_name}_training_latest.png"
            fig.savefig(str(latest), dpi=150, bbox_inches="tight")

            plt.close(fig)

            # Optional sample visualization
            if self.sample_fn is not None:
                try:
                    sfig, _ = self.sample_fn(step)
                    sample_path = out / f"{self.model_name}_samples_latest.png"
                    sfig.savefig(str(sample_path), dpi=150, bbox_inches="tight")
                    plt.close(sfig)
                except Exception as exc:
                    _warn(f"sample_fn failed at {self.x_label}={step}: {exc}")

        except Exception as exc:
            _warn(f"Failed to save training plot at {self.x_label}={step}: {exc}")

    def _update_live(self, step: int) -> None:
        """Redraw the live matplotlib window."""
        try:
            if self._fig is None:
                plt.ion()
                loss_metrics, other_metrics = _group_metrics(self.metrics)
                n_rows = max(1, int(bool(loss_metrics)) + int(bool(other_metrics)))
                self._fig, _axes = plt.subplots(n_rows, 1, figsize=(10, 4 * n_rows), squeeze=False)
                self._axes = [ax for row in _axes for ax in row]
                plt.show(block=False)

            # Rebuild the figure content in-place by clearing and re-plotting
            for ax in self._axes:
                ax.clear()

            loss_metrics, other_metrics = _group_metrics(self.metrics)
            ax_idx = 0
            if loss_metrics and ax_idx < len(self._axes):
                ax = self._axes[ax_idx]
                ax_idx += 1
                for m in loss_metrics:
                    vals = self.history[m]
                    if vals:
                        ax.plot(self._steps, vals, label=m, color=_metric_color(m))
                ax.set_ylabel("Loss")
                ax.legend(fontsize=8)
            if other_metrics and ax_idx < len(self._axes):
                ax = self._axes[ax_idx]
                for m in other_metrics:
                    vals = self.history[m]
                    if vals:
                        ax.plot(self._steps, vals, label=m, color=_metric_color(m))
                ax.set_ylabel("Metric")
                ax.legend(fontsize=8)

            self._fig.suptitle(f"{self.model_name}  {self.x_label}={step}", fontsize=10)
            self._fig.tight_layout()
            self._fig.canvas.draw()
            self._fig.canvas.flush_events()
        except Exception as exc:
            _warn(f"Live plot update failed: {exc}")
            self.live = False  # Disable further attempts


# ---------------------------------------------------------------------------
# Utility functions
# ---------------------------------------------------------------------------

_METRIC_COLORS = {
    "train_loss": "#e06c75",
    "val_loss": "#61afef",
    "train_mse": "#e06c75",
    "val_mse": "#61afef",
    "val_f1": "#98c379",
    "val_auc": "#c678dd",
    "val_r2": "#e5c07b",
    "reward": "#56b6c2",
    "episode_reward": "#56b6c2",
    "episode_cost": "#d19a66",
    "loss": "#e06c75",
}

_COLOR_CYCLE = [
    "#e06c75", "#61afef", "#98c379", "#c678dd",
    "#e5c07b", "#56b6c2", "#d19a66", "#abb2bf",
]
_color_index = 0


def _metric_color(name: str) -> str:
    """Return a consistent color for a metric name."""
    global _color_index
    if name in _METRIC_COLORS:
        return _METRIC_COLORS[name]
    # Assign from cycle and cache
    color = _COLOR_CYCLE[_color_index % len(_COLOR_CYCLE)]
    _METRIC_COLORS[name] = color
    _color_index += 1
    return color


def _is_nan(v: float) -> bool:
    """Return True if v is NaN."""
    import math
    try:
        return math.isnan(v)
    except (TypeError, ValueError):
        return True


def _print_summary(step: int, values: dict[str, float], best: dict[str, float]) -> None:
    """Print a compact one-line progress summary to stdout."""
    parts = []
    for k, v in values.items():
        if not _is_nan(v):
            b = best.get(k)
            star = "*" if (b is not None and abs(v - b) < 1e-10) else " "
            parts.append(f"{k}={v:.5g}{star}")
    summary = "  ".join(parts)
    print(f"[viz] step={step:6d}  {summary}", flush=True)


def _warn(msg: str) -> None:
    """Print a non-fatal warning."""
    print(f"[training_viz WARNING] {msg}", file=sys.stderr, flush=True)
