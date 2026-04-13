"""Pareto front visualization for MOEA/D multi-objective placement.

Provides plotting utilities for:
  - 2D and 3D Pareto front scatter plots
  - Knee-point highlighting
  - Crowding distance heatmaps
  - Objective trade-off parallel-coordinate plots
  - Convergence tracking across MOEA/D generations

All functions accept plain NumPy arrays / lists so they can be used
independently of the Zig engine (e.g. for post-hoc analysis of logged
archives).

Dependencies: numpy, matplotlib (optional: plotly for interactive 3D).
"""

from __future__ import annotations

import logging
from dataclasses import dataclass, field
from pathlib import Path
from typing import Optional, Sequence

import numpy as np

logger = logging.getLogger(__name__)


# ---------------------------------------------------------------------------
# Data types
# ---------------------------------------------------------------------------


@dataclass
class ParetoSolution:
    """A single solution in the Pareto archive."""

    hpwl: float
    area: float
    constraint: float
    positions: Optional[np.ndarray] = None  # (N, 2) device positions
    crowding_distance: float = 0.0
    weight_vector: Optional[tuple[float, float, float]] = None


@dataclass
class ParetoFront:
    """Collection of non-dominated solutions with metadata."""

    solutions: list[ParetoSolution] = field(default_factory=list)
    knee_index: Optional[int] = None
    ideal_point: Optional[tuple[float, float, float]] = None
    nadir_point: Optional[tuple[float, float, float]] = None

    @property
    def objectives(self) -> np.ndarray:
        """Return (N, 3) array of [hpwl, area, constraint] for all solutions."""
        if not self.solutions:
            return np.empty((0, 3), dtype=np.float64)
        return np.array(
            [[s.hpwl, s.area, s.constraint] for s in self.solutions],
            dtype=np.float64,
        )

    @property
    def size(self) -> int:
        """Number of solutions in the Pareto front."""
        return len(self.solutions)

    def compute_ideal_nadir(self) -> None:
        """Compute ideal (utopia) and nadir points from the archive."""
        if not self.solutions:
            return
        obj = self.objectives
        self.ideal_point = tuple(obj.min(axis=0).tolist())
        self.nadir_point = tuple(obj.max(axis=0).tolist())

    def find_knee_point(self) -> int:
        """Select the knee point -- closest to ideal in normalised space."""
        obj = self.objectives
        if obj.shape[0] == 0:
            return 0

        mins = obj.min(axis=0)
        ranges = obj.max(axis=0) - mins
        ranges = np.where(ranges < 1e-12, 1.0, ranges)

        normalised = (obj - mins) / ranges
        distances = np.linalg.norm(normalised, axis=1)
        self.knee_index = int(np.argmin(distances))
        return self.knee_index


# ---------------------------------------------------------------------------
# Dominance utilities
# ---------------------------------------------------------------------------


def is_dominated(a: np.ndarray, b: np.ndarray) -> bool:
    """Return True if solution `a` is dominated by `b` (all objectives minimised)."""
    return bool(np.all(b <= a) and np.any(b < a))


def compute_pareto_front(objectives: np.ndarray) -> np.ndarray:
    """Return boolean mask of non-dominated solutions.

    Parameters
    ----------
    objectives : ndarray, shape (N, M)
        Objective values to minimise.

    Returns
    -------
    mask : ndarray, shape (N,), dtype bool
        True for non-dominated solutions.
    """
    n = objectives.shape[0]
    mask = np.ones(n, dtype=bool)
    for i in range(n):
        if not mask[i]:
            continue
        for j in range(n):
            if i == j or not mask[j]:
                continue
            if is_dominated(objectives[i], objectives[j]):
                mask[i] = False
                break
    return mask


def crowding_distance(objectives: np.ndarray) -> np.ndarray:
    """Compute crowding distance for a set of objective vectors.

    Parameters
    ----------
    objectives : ndarray, shape (N, M)

    Returns
    -------
    distances : ndarray, shape (N,)
    """
    n, m = objectives.shape
    if n <= 2:
        return np.full(n, np.inf)

    distances = np.zeros(n)
    for dim in range(m):
        order = np.argsort(objectives[:, dim])
        distances[order[0]] = np.inf
        distances[order[-1]] = np.inf

        f_range = objectives[order[-1], dim] - objectives[order[0], dim]
        if f_range < 1e-12:
            continue

        for k in range(1, n - 1):
            gap = objectives[order[k + 1], dim] - objectives[order[k - 1], dim]
            distances[order[k]] += gap / f_range

    return distances


# ---------------------------------------------------------------------------
# Weight vector generation (mirrors the Zig-side logic for consistency)
# ---------------------------------------------------------------------------


def generate_simplex_weights(k: int = 21, dims: int = 3) -> np.ndarray:
    """Generate approximately K uniformly distributed weight vectors on the simplex.

    Parameters
    ----------
    k : int
        Target number of weight vectors.
    dims : int
        Number of objective dimensions (default 3).

    Returns
    -------
    weights : ndarray, shape (K', dims) where K' <= k
        Each row sums to 1.0.
    """
    # Find the largest number of divisions D such that C(D+dims-1, dims-1) <= k.
    from math import comb

    divisions = 1
    while comb(divisions + dims - 1, dims - 1) <= k:
        divisions += 1
    divisions -= 1
    divisions = max(divisions, 1)

    # Enumerate all compositions of `divisions` into `dims` non-negative parts.
    weights = []

    def _enumerate(remaining: int, depth: int, current: list[int]) -> None:
        if depth == dims - 1:
            current.append(remaining)
            weights.append([c / divisions for c in current])
            current.pop()
            return
        for i in range(remaining + 1):
            current.append(i)
            _enumerate(remaining - i, depth + 1, current)
            current.pop()

    _enumerate(divisions, 0, [])

    result = np.array(weights[:k], dtype=np.float64)
    return result


# ---------------------------------------------------------------------------
# Plotting functions
# ---------------------------------------------------------------------------


def plot_pareto_2d(
    front: ParetoFront,
    x_obj: int = 0,
    y_obj: int = 1,
    labels: Sequence[str] = ("HPWL", "Area", "Constraint"),
    title: str = "Pareto Front",
    save_path: Optional[str | Path] = None,
    show: bool = True,
    figsize: tuple[float, float] = (8, 6),
) -> object:
    """2D scatter plot of two objectives from the Pareto front.

    Parameters
    ----------
    front : ParetoFront
        The Pareto front to visualise.
    x_obj, y_obj : int
        Objective indices (0=hpwl, 1=area, 2=constraint).
    labels : sequence of str
        Names for the three objectives.
    title : str
        Plot title.
    save_path : str or Path, optional
        If given, save the figure to this path.
    show : bool
        Whether to call plt.show().
    figsize : tuple
        Figure size in inches.

    Returns
    -------
    fig : matplotlib Figure
    """
    import matplotlib.pyplot as plt

    obj = front.objectives
    if obj.shape[0] == 0:
        logger.warning("Empty Pareto front; nothing to plot")
        fig, ax = plt.subplots(figsize=figsize)
        ax.set_title(title + " (empty)")
        return fig

    fig, ax = plt.subplots(figsize=figsize)

    # All solutions.
    ax.scatter(
        obj[:, x_obj],
        obj[:, y_obj],
        c="steelblue",
        s=40,
        alpha=0.7,
        edgecolors="k",
        linewidths=0.5,
        label="Pareto solutions",
        zorder=2,
    )

    # Highlight knee point.
    knee = front.knee_index
    if knee is not None and 0 <= knee < obj.shape[0]:
        ax.scatter(
            obj[knee, x_obj],
            obj[knee, y_obj],
            c="red",
            s=120,
            marker="*",
            edgecolors="k",
            linewidths=0.8,
            label="Knee point",
            zorder=3,
        )

    # Ideal point.
    if front.ideal_point is not None:
        ax.scatter(
            front.ideal_point[x_obj],
            front.ideal_point[y_obj],
            c="green",
            s=80,
            marker="D",
            edgecolors="k",
            linewidths=0.8,
            label="Ideal point",
            zorder=3,
        )

    ax.set_xlabel(labels[x_obj], fontsize=12)
    ax.set_ylabel(labels[y_obj], fontsize=12)
    ax.set_title(title, fontsize=14)
    ax.legend(fontsize=10)
    ax.grid(True, alpha=0.3)
    fig.tight_layout()

    if save_path:
        fig.savefig(str(save_path), dpi=150, bbox_inches="tight")
        logger.info("Saved Pareto plot to %s", save_path)

    if show:
        plt.show()

    return fig


def plot_pareto_3d(
    front: ParetoFront,
    labels: Sequence[str] = ("HPWL", "Area", "Constraint"),
    title: str = "3D Pareto Front",
    save_path: Optional[str | Path] = None,
    show: bool = True,
    figsize: tuple[float, float] = (10, 8),
) -> object:
    """3D scatter plot of all three objectives.

    Parameters
    ----------
    front : ParetoFront
        The Pareto front to visualise.
    labels : sequence of str
        Names for the three objectives.
    title : str
        Plot title.
    save_path : str or Path, optional
        If given, save the figure to this path.
    show : bool
        Whether to call plt.show().
    figsize : tuple
        Figure size in inches.

    Returns
    -------
    fig : matplotlib Figure
    """
    import matplotlib.pyplot as plt

    obj = front.objectives
    if obj.shape[0] == 0:
        logger.warning("Empty Pareto front; nothing to plot")
        fig = plt.figure(figsize=figsize)
        return fig

    fig = plt.figure(figsize=figsize)
    ax = fig.add_subplot(111, projection="3d")

    # Colour by crowding distance if available.
    cd = np.array([s.crowding_distance for s in front.solutions])
    finite_cd = cd[np.isfinite(cd)]
    if len(finite_cd) > 0 and np.ptp(finite_cd) > 1e-12:
        # Clamp inf to max finite value for color mapping.
        cd_clamped = np.where(np.isfinite(cd), cd, finite_cd.max())
        scatter = ax.scatter(
            obj[:, 0], obj[:, 1], obj[:, 2],
            c=cd_clamped, cmap="viridis", s=50, alpha=0.8,
            edgecolors="k", linewidths=0.3,
        )
        fig.colorbar(scatter, ax=ax, label="Crowding Distance", shrink=0.6)
    else:
        ax.scatter(
            obj[:, 0], obj[:, 1], obj[:, 2],
            c="steelblue", s=50, alpha=0.8,
            edgecolors="k", linewidths=0.3,
        )

    # Highlight knee.
    knee = front.knee_index
    if knee is not None and 0 <= knee < obj.shape[0]:
        ax.scatter(
            [obj[knee, 0]], [obj[knee, 1]], [obj[knee, 2]],
            c="red", s=150, marker="*", edgecolors="k", linewidths=0.8,
            label="Knee point",
        )

    ax.set_xlabel(labels[0])
    ax.set_ylabel(labels[1])
    ax.set_zlabel(labels[2])
    ax.set_title(title, fontsize=14)
    if knee is not None:
        ax.legend()
    fig.tight_layout()

    if save_path:
        fig.savefig(str(save_path), dpi=150, bbox_inches="tight")
        logger.info("Saved 3D Pareto plot to %s", save_path)

    if show:
        plt.show()

    return fig


def plot_parallel_coordinates(
    front: ParetoFront,
    labels: Sequence[str] = ("HPWL", "Area", "Constraint"),
    title: str = "Objective Trade-offs",
    save_path: Optional[str | Path] = None,
    show: bool = True,
    figsize: tuple[float, float] = (10, 5),
) -> object:
    """Parallel-coordinate plot showing trade-offs across objectives.

    Each line is one Pareto solution; the knee point is highlighted in red.

    Parameters
    ----------
    front : ParetoFront
    labels : sequence of str
    title : str
    save_path : str or Path, optional
    show : bool
    figsize : tuple

    Returns
    -------
    fig : matplotlib Figure
    """
    import matplotlib.pyplot as plt
    from matplotlib.collections import LineCollection

    obj = front.objectives
    if obj.shape[0] == 0:
        fig, ax = plt.subplots(figsize=figsize)
        ax.set_title(title + " (empty)")
        return fig

    # Normalise each objective to [0, 1].
    mins = obj.min(axis=0)
    ranges = obj.max(axis=0) - mins
    ranges = np.where(ranges < 1e-12, 1.0, ranges)
    norm = (obj - mins) / ranges

    n_obj = obj.shape[1]
    x_ticks = np.arange(n_obj)

    fig, ax = plt.subplots(figsize=figsize)

    # Draw each solution as a polyline.
    for i in range(norm.shape[0]):
        color = "red" if i == front.knee_index else "steelblue"
        alpha = 1.0 if i == front.knee_index else 0.4
        lw = 2.5 if i == front.knee_index else 1.0
        zorder = 3 if i == front.knee_index else 1
        ax.plot(x_ticks, norm[i], c=color, alpha=alpha, lw=lw, zorder=zorder)

    ax.set_xticks(x_ticks)
    ax.set_xticklabels(labels[:n_obj], fontsize=12)
    ax.set_ylabel("Normalised Objective Value", fontsize=11)
    ax.set_title(title, fontsize=14)
    ax.set_ylim(-0.05, 1.05)
    ax.grid(True, axis="x", alpha=0.3)

    # Add a manual legend.
    from matplotlib.lines import Line2D
    legend_elements = [
        Line2D([0], [0], color="steelblue", alpha=0.6, lw=1.5, label="Pareto solutions"),
        Line2D([0], [0], color="red", lw=2.5, label="Knee point"),
    ]
    ax.legend(handles=legend_elements, fontsize=10)

    fig.tight_layout()

    if save_path:
        fig.savefig(str(save_path), dpi=150, bbox_inches="tight")

    if show:
        plt.show()

    return fig


def plot_convergence(
    history: list[list[float]],
    objective_names: Sequence[str] = ("HPWL", "Area", "Constraint"),
    title: str = "MOEA/D Convergence",
    save_path: Optional[str | Path] = None,
    show: bool = True,
    figsize: tuple[float, float] = (10, 4),
) -> object:
    """Plot convergence of each objective's best value over generations.

    Parameters
    ----------
    history : list of lists
        history[gen] = [best_hpwl, best_area, best_constraint] per generation.
    objective_names : sequence of str
    title : str
    save_path : str or Path, optional
    show : bool
    figsize : tuple

    Returns
    -------
    fig : matplotlib Figure
    """
    import matplotlib.pyplot as plt

    hist = np.array(history)
    if hist.ndim != 2 or hist.shape[0] == 0:
        fig, ax = plt.subplots(figsize=figsize)
        ax.set_title(title + " (no data)")
        return fig

    n_gen, n_obj = hist.shape
    gens = np.arange(1, n_gen + 1)

    fig, axes = plt.subplots(1, n_obj, figsize=figsize, sharey=False)
    if n_obj == 1:
        axes = [axes]

    for dim in range(n_obj):
        ax = axes[dim]
        ax.plot(gens, hist[:, dim], color="steelblue", lw=1.5)
        ax.fill_between(gens, hist[:, dim], alpha=0.1, color="steelblue")
        ax.set_xlabel("Generation")
        ax.set_ylabel(objective_names[dim] if dim < len(objective_names) else f"Obj {dim}")
        ax.set_title(objective_names[dim] if dim < len(objective_names) else f"Objective {dim}")
        ax.grid(True, alpha=0.3)

    fig.suptitle(title, fontsize=14, y=1.02)
    fig.tight_layout()

    if save_path:
        fig.savefig(str(save_path), dpi=150, bbox_inches="tight")

    if show:
        plt.show()

    return fig


# ---------------------------------------------------------------------------
# Convenience: build ParetoFront from raw objective arrays
# ---------------------------------------------------------------------------


def build_pareto_front(
    objectives: np.ndarray,
    positions: Optional[list[np.ndarray]] = None,
    weight_vectors: Optional[np.ndarray] = None,
) -> ParetoFront:
    """Build a ParetoFront from raw objective data.

    Parameters
    ----------
    objectives : ndarray, shape (N, 3)
        [hpwl, area, constraint] per solution.
    positions : list of ndarray, optional
        Per-solution device positions.
    weight_vectors : ndarray, shape (N, 3), optional
        Weight vectors used for each solution.

    Returns
    -------
    front : ParetoFront
        With non-dominated filter applied and knee point selected.
    """
    mask = compute_pareto_front(objectives)
    nd_obj = objectives[mask]
    nd_indices = np.where(mask)[0]

    cd = crowding_distance(nd_obj)

    solutions = []
    for k, idx in enumerate(nd_indices):
        sol = ParetoSolution(
            hpwl=float(nd_obj[k, 0]),
            area=float(nd_obj[k, 1]),
            constraint=float(nd_obj[k, 2]),
            crowding_distance=float(cd[k]),
        )
        if positions is not None and idx < len(positions):
            sol.positions = positions[idx]
        if weight_vectors is not None and idx < weight_vectors.shape[0]:
            sol.weight_vector = tuple(weight_vectors[idx].tolist())
        solutions.append(sol)

    front = ParetoFront(solutions=solutions)
    front.compute_ideal_nadir()
    if solutions:
        front.find_knee_point()

    return front
