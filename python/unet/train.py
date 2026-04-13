"""Training loop for the UNet DRC Violation Heatmap Predictor.

Generates synthetic (layout, violation_mask) training pairs where violations
are physically meaningful: spacing violations (rectangles too close), width
violations (rectangles too narrow), and enclosure violations.  The model
learns to predict a binary violation heatmap from the multi-channel layout
representation.

Loss: focal loss (+ optional BCE blend) to handle extreme class imbalance.
Metrics: precision, recall, F1, ROC-AUC on binary violation maps.

Performance features:
    - Mixed-precision training (AMP) on CUDA for ~2x throughput on 512x512
      images with the 31M-parameter UNet.
    - torch.compile (PyTorch 2+) for graph-level kernel fusion.
    - DataLoader workers + pin_memory on CUDA for async host-to-device copies.
    - Pre-generated dataset cache (fixtures/benchmark/cache/unet_synth.pt) to skip
      the slow synthetic data generation on subsequent runs.
"""

from __future__ import annotations

import argparse
import logging
import math
import pathlib
from typing import Any

import numpy as np
import torch
import torch.nn as nn
import torch.nn.functional as F
from scipy import ndimage
from torch.utils.data import DataLoader, TensorDataset

from torch.optim.swa_utils import AveragedModel, SWALR, update_bn

from .model import IMG_SIZE, IN_CHANNELS, GraphConditioner, build_model
from ..utility.repair_rl import (
    DRCRepairEnv,
    DRCRepairPolicy,
    predict_rl_repair,
    train_rl_repair,
)

# visualization
try:
    from ..visualizer import TrainingVisualizer as _TrainingVisualizer
except ImportError:
    _TrainingVisualizer = None  # type: ignore[assignment,misc]

logger = logging.getLogger(__name__)


# ---------------------------------------------------------------------------
# Test-Time Augmentation (TTA) with D4 symmetry
# ---------------------------------------------------------------------------


def _d4_forward_transforms() -> (
    list[tuple[str, dict[str, int | tuple[int, ...]]]]
):
    """Return the 8 D4 group transforms as (name, kwargs) pairs.

    Each entry is a pair of ``(label, transform_kwargs)`` where the transform
    can be reconstructed from ``torch.rot90`` and ``torch.flip`` calls.

    The 8 elements of D4 are:
        identity, rot90, rot180, rot270,
        hflip, vflip, rot90+hflip, rot90+vflip
    """
    return [
        ("identity", {}),
        ("rot90", {"k": 1}),
        ("rot180", {"k": 2}),
        ("rot270", {"k": 3}),
        ("hflip", {"flip_dims": (-1,)}),
        ("vflip", {"flip_dims": (-2,)}),
        ("rot90_hflip", {"k": 1, "flip_dims": (-1,)}),
        ("rot90_vflip", {"k": 1, "flip_dims": (-2,)}),
    ]


def _apply_d4_transform(
    x: torch.Tensor, k: int = 0, flip_dims: tuple[int, ...] | None = None
) -> torch.Tensor:
    """Apply a D4 transform: rotate by k*90 degrees, then optionally flip."""
    if k:
        x = torch.rot90(x, k, dims=(-2, -1))
    if flip_dims is not None:
        x = torch.flip(x, dims=flip_dims)
    return x


def _apply_d4_inverse(
    x: torch.Tensor, k: int = 0, flip_dims: tuple[int, ...] | None = None
) -> torch.Tensor:
    """Apply the inverse of a D4 transform: undo flip first, then rotate back."""
    # Flip is its own inverse.
    if flip_dims is not None:
        x = torch.flip(x, dims=flip_dims)
    # Inverse of rot90(k) is rot90(4-k) (equivalently rot90(-k)).
    if k:
        x = torch.rot90(x, -k, dims=(-2, -1))
    return x


@torch.no_grad()
def predict_with_tta(
    model: nn.Module,
    x: torch.Tensor,
    graph_cond: torch.Tensor | None = None,
    use_amp: bool = False,
) -> torch.Tensor:
    """Run inference with D4 Test-Time Augmentation.

    Applies all 8 D4 transforms to the input, runs the model on each,
    inverse-transforms each prediction back to the original orientation,
    and averages the 8 probability maps (after sigmoid, in probability space).

    Args:
        model: The UNet model (must be in eval mode).
        x: (B, C, H, W) input tensor.
        graph_cond: Optional (B, cond_dim) graph conditioning vector.
        use_amp: Whether to use automatic mixed precision.

    Returns:
        (B, 1, H, W) averaged probability map in [0, 1].
    """
    transforms = _d4_forward_transforms()
    prob_sum = torch.zeros(
        x.shape[0], 1, x.shape[2], x.shape[3],
        device=x.device, dtype=x.dtype,
    )

    for _label, kwargs in transforms:
        x_t = _apply_d4_transform(x, **kwargs)
        with torch.amp.autocast("cuda", enabled=use_amp):
            logits_t = model(x_t, graph_cond=graph_cond)
        probs_t = torch.sigmoid(logits_t)
        # Inverse-transform the prediction back to original orientation.
        probs_orig = _apply_d4_inverse(probs_t, **kwargs)
        prob_sum += probs_orig

    return prob_sum / len(transforms)


# ---------------------------------------------------------------------------
# Morphological post-processing
# ---------------------------------------------------------------------------


def apply_morphological_cleanup(
    prob_map: np.ndarray,
    threshold: float = 0.5,
) -> np.ndarray:
    """Post-process a violation probability map to remove noise.

    Steps:
        1. Threshold the probability map to obtain a binary mask.
        2. Morphological opening with a 3x3 disk structuring element to
           remove isolated false-positive pixels.
        3. Remove connected components smaller than 4 pixels.

    Args:
        prob_map: (H, W) or (B, 1, H, W) float probability map in [0, 1].
        threshold: Probability threshold for binarisation.

    Returns:
        Binary mask with the same shape as *prob_map* (float32, values 0/1).
    """
    squeeze_dims: list[int] = []
    arr = prob_map
    # Normalise to (H, W) for processing.
    if arr.ndim == 4:
        # (B, 1, H, W) -- process each sample independently.
        results = np.empty_like(arr)
        for b in range(arr.shape[0]):
            results[b, 0] = apply_morphological_cleanup(arr[b, 0], threshold)
        return results
    if arr.ndim == 3:
        # (1, H, W) -> (H, W)
        squeeze_dims.append(0)
        arr = arr[0]

    # Step 1: threshold.
    binary = (arr >= threshold).astype(np.float32)

    # Step 2: morphological closing (fill small gaps) then remove truly
    # isolated single-pixel noise.  DRC violations are often only 1-3 pixels
    # wide, so aggressive opening/filtering destroys true positives.
    cross3 = np.array(
        [[0, 1, 0],
         [1, 1, 1],
         [0, 1, 0]],
        dtype=np.uint8,
    )
    # Close small gaps between nearby violation pixels.
    binary = ndimage.binary_closing(binary, structure=cross3).astype(np.float32)
    # Remove only truly isolated single pixels (opening with minimal kernel).
    binary = ndimage.binary_opening(binary, structure=np.ones((2, 2), dtype=np.uint8)).astype(np.float32)

    # Step 3: remove isolated single-pixel components only.
    labelled, n_features = ndimage.label(binary)
    if n_features > 0:
        component_sizes = ndimage.sum(binary, labelled, range(1, n_features + 1))
        for comp_idx, size in enumerate(component_sizes, start=1):
            if size < 2:
                binary[labelled == comp_idx] = 0.0

    # Restore original dimensions.
    for _ in squeeze_dims:
        binary = np.expand_dims(binary, 0)

    return binary


# ---------------------------------------------------------------------------
# Focal Tversky Loss
# ---------------------------------------------------------------------------


def tversky_index(
    pred_probs: torch.Tensor,
    target: torch.Tensor,
    alpha: float = 0.15,
    beta: float = 0.85,
    smooth: float = 1e-6,
) -> torch.Tensor:
    """Tversky index (generalised Dice).

    Args:
        pred_probs: (B, 1, H, W) predicted probabilities (after sigmoid).
        target: (B, 1, H, W) binary ground truth.
        alpha: Weight for false-positive penalty.
        beta: Weight for false-negative penalty (higher = recall-biased).
        smooth: Smoothing constant to avoid division by zero.

    Returns:
        Scalar Tversky index in [0, 1].
    """
    tp = (pred_probs * target).sum()
    fp = (pred_probs * (1.0 - target)).sum()
    fn = ((1.0 - pred_probs) * target).sum()
    return (tp + smooth) / (tp + alpha * fp + beta * fn + smooth)


def focal_tversky_loss(
    pred_logits: torch.Tensor,
    target: torch.Tensor,
    alpha: float = 0.15,
    beta: float = 0.85,
    gamma: float = 0.75,
) -> torch.Tensor:
    """Focal Tversky loss for binary segmentation with class imbalance.

    Focuses training on hard examples (low Tversky index) by raising the
    complement to a power ``gamma > 1``.

    Args:
        pred_logits: (B, 1, H, W) raw logits from the model.
        target: (B, 1, H, W) binary ground truth (0 or 1).
        alpha: Tversky false-positive weight.
        beta: Tversky false-negative weight.
        gamma: Focal exponent (> 1 amplifies hard examples).

    Returns:
        Scalar loss.
    """
    probs = torch.sigmoid(pred_logits)
    ti = tversky_index(probs, target, alpha, beta)
    return (1.0 - ti) ** gamma


def boundary_dou_loss(
    pred_logits: torch.Tensor,
    target: torch.Tensor,
    theta: float = 3.0,
    smooth: float = 1e-6,
) -> torch.Tensor:
    """Boundary Distance-over-Union loss for thin spatial structures.

    Extracts boundary pixels from both prediction and target using
    morphological operations (max_pool - erosion), then computes a
    distance-weighted IoU focused on boundary accuracy.

    Args:
        pred_logits: (B, 1, H, W) raw logits.
        target: (B, 1, H, W) binary ground truth.
        theta: Boundary extraction kernel size.
        smooth: Smoothing constant.

    Returns:
        Scalar boundary DoU loss in [0, 1].
    """
    probs = torch.sigmoid(pred_logits)

    # Extract boundaries via morphological gradient (dilation - erosion).
    kernel_size = int(theta)
    if kernel_size % 2 == 0:
        kernel_size += 1
    pad = kernel_size // 2

    # Target boundaries.
    t_dilated = F.max_pool2d(target, kernel_size, stride=1, padding=pad)
    t_eroded = -F.max_pool2d(-target, kernel_size, stride=1, padding=pad)
    t_boundary = t_dilated - t_eroded

    # Prediction boundaries.
    p_dilated = F.max_pool2d(probs, kernel_size, stride=1, padding=pad)
    p_eroded = -F.max_pool2d(-probs, kernel_size, stride=1, padding=pad)
    p_boundary = p_dilated - p_eroded

    # Boundary IoU.
    intersection = (p_boundary * t_boundary).sum()
    union = p_boundary.sum() + t_boundary.sum() - intersection

    boundary_iou = (intersection + smooth) / (union + smooth)
    return 1.0 - boundary_iou


# ---------------------------------------------------------------------------
# Metrics
# ---------------------------------------------------------------------------


def compute_metrics(
    pred_logits: torch.Tensor,
    target: torch.Tensor,
    threshold: float = 0.5,
) -> dict[str, float]:
    """Compute binary classification metrics on violation maps.

    Args:
        pred_logits: (B, 1, H, W) raw logits.
        target: (B, 1, H, W) binary ground truth.
        threshold: Probability threshold for binary prediction.

    Returns:
        Dict with precision, recall, f1, auc.
    """
    with torch.no_grad():
        probs = torch.sigmoid(pred_logits)
    return compute_metrics_from_probs(probs, target, threshold)


def compute_metrics_from_probs(
    probs: torch.Tensor,
    target: torch.Tensor,
    threshold: float = 0.5,
) -> dict[str, float]:
    """Compute binary classification metrics from probability maps.

    Like :func:`compute_metrics` but accepts pre-sigmoid probabilities,
    which is needed for TTA where predictions are averaged in probability
    space.

    Args:
        probs: (B, 1, H, W) predicted probabilities in [0, 1].
        target: (B, 1, H, W) binary ground truth.
        threshold: Probability threshold for binary prediction.

    Returns:
        Dict with precision, recall, f1, auc.
    """
    with torch.no_grad():
        preds = (probs >= threshold).float()

        tp = (preds * target).sum().item()
        fp = (preds * (1.0 - target)).sum().item()
        fn = ((1.0 - preds) * target).sum().item()

        precision = tp / max(tp + fp, 1e-8)
        recall = tp / max(tp + fn, 1e-8)
        f1 = 2.0 * precision * recall / max(precision + recall, 1e-8)

        # Approximate AUC via a simple binned ROC.
        auc = _approx_auc(probs.view(-1), target.view(-1))

    return {
        "precision": precision,
        "recall": recall,
        "f1": f1,
        "auc": auc,
    }


def _approx_auc(probs: torch.Tensor, targets: torch.Tensor, n_bins: int = 200) -> float:
    """Fast approximate ROC-AUC using threshold sweep.

    This avoids pulling huge tensors to CPU for sklearn. For small datasets
    the approximation is very close to the exact value.
    """
    if targets.sum().item() < 1 or (1.0 - targets).sum().item() < 1:
        return 0.5  # Undefined when only one class present.

    thresholds = torch.linspace(1.0, 0.0, n_bins + 1, device=probs.device)
    tpr_prev, fpr_prev = 0.0, 0.0
    auc = 0.0
    n_pos = targets.sum().item()
    n_neg = targets.numel() - n_pos

    for t in thresholds:
        preds = (probs >= t).float()
        tp = (preds * targets).sum().item()
        fp = (preds * (1.0 - targets)).sum().item()
        tpr = tp / max(n_pos, 1e-8)
        fpr = fp / max(n_neg, 1e-8)
        # Trapezoidal rule.
        auc += 0.5 * (tpr + tpr_prev) * (fpr - fpr_prev)
        tpr_prev, fpr_prev = tpr, fpr

    return max(0.0, min(1.0, auc))


# ---------------------------------------------------------------------------
# Synthetic DRC data generation
# ---------------------------------------------------------------------------


def generate_drc_training_data(
    n_samples: int,
    img_size: int = IMG_SIZE,
    seed: int = 42,
) -> tuple[torch.Tensor, torch.Tensor]:
    """Generate (layout, violation_mask) pairs with known DRC violations.

    Channels (input):
        0: metal1 density
        1: metal2 density
        2: via density
        3: poly density
        4: diffusion density

    Target:
        1-channel binary mask where 1 = DRC violation location, 0 = clean.

    Violation types generated:
        - Spacing violations: two rectangles on the same layer placed closer
          than MIN_SPACING pixels apart.
        - Width violations: rectangles narrower than MIN_WIDTH pixels.
        - Enclosure violations: via not fully enclosed by metal on both layers.

    Args:
        n_samples: Number of samples to generate.
        img_size: Spatial resolution (square images).
        seed: Random seed for reproducibility.

    Returns:
        (inputs, targets): inputs is (N, 5, H, W), targets is (N, 1, H, W).
    """
    MIN_SPACING = 8   # pixels - minimum spacing rule
    MIN_WIDTH = 4     # pixels - minimum width rule
    VIA_ENCLOSURE = 3 # pixels - via must be enclosed by metal on each side

    rng = np.random.default_rng(seed)

    inputs = np.zeros((n_samples, IN_CHANNELS, img_size, img_size), dtype=np.float32)
    targets = np.zeros((n_samples, 1, img_size, img_size), dtype=np.float32)

    for i in range(n_samples):
        # -- Place rectangles on each layer --
        # Track rectangles per layer for spacing checks.
        layer_rects: dict[int, list[tuple[int, int, int, int]]] = {ch: [] for ch in range(IN_CHANNELS)}

        for ch in range(IN_CHANNELS):
            n_rects = rng.integers(5, 25)
            for _ in range(n_rects):
                w = rng.integers(3, min(50, img_size // 4))
                h = rng.integers(3, min(50, img_size // 4))
                x0 = rng.integers(0, max(1, img_size - w))
                y0 = rng.integers(0, max(1, img_size - h))
                val = rng.uniform(0.6, 1.0)
                inputs[i, ch, y0:y0 + h, x0:x0 + w] = val
                layer_rects[ch].append((x0, y0, w, h))

                # -- Width violation: rectangle too narrow --
                if w < MIN_WIDTH or h < MIN_WIDTH:
                    # Mark the entire narrow rectangle as a violation.
                    targets[i, 0, y0:y0 + h, x0:x0 + w] = 1.0

        # -- Spacing violations within each layer --
        for ch in range(IN_CHANNELS):
            rects = layer_rects[ch]
            for a_idx in range(len(rects)):
                ax, ay, aw, ah = rects[a_idx]
                for b_idx in range(a_idx + 1, len(rects)):
                    bx, by, bw, bh = rects[b_idx]

                    # Compute gap between rectangles (axis-aligned).
                    gap_x = max(0, max(bx - (ax + aw), ax - (bx + bw)))
                    gap_y = max(0, max(by - (ay + ah), ay - (by + bh)))

                    # Check if rectangles overlap vertically/horizontally
                    # (they must be adjacent, not diagonal, for spacing rule).
                    overlap_x = not (ax + aw <= bx or bx + bw <= ax)
                    overlap_y = not (ay + ah <= by or by + bh <= ay)

                    if overlap_y and 0 < gap_x < MIN_SPACING:
                        # Horizontal spacing violation — mark the gap region.
                        gap_left = min(ax + aw, bx + bw)
                        gap_right = max(ax, bx)
                        if gap_left > gap_right:
                            gap_left, gap_right = gap_right, gap_left
                        y_top = max(ay, by)
                        y_bot = min(ay + ah, by + bh)
                        if y_top < y_bot and gap_left < gap_right:
                            targets[i, 0, y_top:y_bot, gap_left:gap_right] = 1.0

                    if overlap_x and 0 < gap_y < MIN_SPACING:
                        # Vertical spacing violation — mark the gap region.
                        gap_top = min(ay + ah, by + bh)
                        gap_bot = max(ay, by)
                        if gap_top > gap_bot:
                            gap_top, gap_bot = gap_bot, gap_top
                        x_left = max(ax, bx)
                        x_right = min(ax + aw, bx + bw)
                        if x_left < x_right and gap_top < gap_bot:
                            targets[i, 0, gap_top:gap_bot, x_left:x_right] = 1.0

        # -- Deliberate spacing violations (force some close placements) --
        n_forced = rng.integers(2, 8)
        for _ in range(n_forced):
            ch = rng.integers(0, IN_CHANNELS)
            w1 = rng.integers(MIN_WIDTH, 30)
            h1 = rng.integers(MIN_WIDTH, 30)
            x1 = rng.integers(0, max(1, img_size - w1 - MIN_SPACING - 30))
            y1 = rng.integers(0, max(1, img_size - max(h1, 30)))

            # Place first rectangle.
            inputs[i, ch, y1:y1 + h1, x1:x1 + w1] = rng.uniform(0.6, 1.0)

            # Place second rectangle with spacing violation.
            gap = rng.integers(1, MIN_SPACING)  # Less than MIN_SPACING.
            w2 = rng.integers(MIN_WIDTH, 30)
            h2 = rng.integers(MIN_WIDTH, 30)
            x2 = x1 + w1 + gap
            y2 = y1 + rng.integers(-min(5, h1 // 2), min(5, h1 // 2) + 1)
            y2 = max(0, min(img_size - h2, y2))

            if x2 + w2 <= img_size and y2 + h2 <= img_size:
                inputs[i, ch, y2:y2 + h2, x2:x2 + w2] = rng.uniform(0.6, 1.0)

                # Mark the gap as violation.
                vy_top = max(y1, y2)
                vy_bot = min(y1 + h1, y2 + h2)
                if vy_top < vy_bot:
                    targets[i, 0, vy_top:vy_bot, x1 + w1:x2] = 1.0

        # -- Width violations (force some narrow rectangles) --
        n_narrow = rng.integers(2, 6)
        for _ in range(n_narrow):
            ch = rng.integers(0, IN_CHANNELS)
            # At least one dimension below MIN_WIDTH.
            if rng.random() < 0.5:
                w = rng.integers(1, MIN_WIDTH)
                h = rng.integers(MIN_WIDTH, 40)
            else:
                w = rng.integers(MIN_WIDTH, 40)
                h = rng.integers(1, MIN_WIDTH)
            x0 = rng.integers(0, max(1, img_size - w))
            y0 = rng.integers(0, max(1, img_size - h))
            inputs[i, ch, y0:y0 + h, x0:x0 + w] = rng.uniform(0.6, 1.0)
            targets[i, 0, y0:y0 + h, x0:x0 + w] = 1.0

        # -- Via enclosure violations --
        n_vias = rng.integers(3, 10)
        for _ in range(n_vias):
            via_size = rng.integers(3, 8)
            vx = rng.integers(VIA_ENCLOSURE, max(VIA_ENCLOSURE + 1, img_size - via_size - VIA_ENCLOSURE))
            vy = rng.integers(VIA_ENCLOSURE, max(VIA_ENCLOSURE + 1, img_size - via_size - VIA_ENCLOSURE))

            # Place via (channel 2).
            inputs[i, 2, vy:vy + via_size, vx:vx + via_size] = 1.0

            if rng.random() < 0.4:
                # Create enclosure violation: metal doesn't fully surround via.
                enc = rng.integers(0, VIA_ENCLOSURE)  # Insufficient enclosure.
                mx = vx - enc
                my = vy - enc
                mw = via_size + 2 * enc
                mh = via_size + 2 * enc
                mx = max(0, mx)
                my = max(0, my)
                inputs[i, 0, my:my + mh, mx:mx + mw] = rng.uniform(0.6, 1.0)
                inputs[i, 1, my:my + mh, mx:mx + mw] = rng.uniform(0.6, 1.0)

                if enc < VIA_ENCLOSURE:
                    # Mark the under-enclosed via edges as violation.
                    targets[i, 0, vy:vy + via_size, vx:vx + via_size] = 1.0
            else:
                # Clean via with proper enclosure.
                enc = VIA_ENCLOSURE
                mx = max(0, vx - enc)
                my = max(0, vy - enc)
                mw = via_size + 2 * enc
                mh = via_size + 2 * enc
                inputs[i, 0, my:min(img_size, my + mh), mx:min(img_size, mx + mw)] = rng.uniform(0.6, 1.0)
                inputs[i, 1, my:min(img_size, my + mh), mx:min(img_size, mx + mw)] = rng.uniform(0.6, 1.0)

    return torch.from_numpy(inputs), torch.from_numpy(targets)


# ---------------------------------------------------------------------------
# Graph feature generation for FiLM conditioning
# ---------------------------------------------------------------------------

# Per-node feature layout:
#   [0]     device type (layer index: 0=metal1, 1=metal2, 2=via, 3=poly, 4=diff)
#   [1:3]   normalised centre position (cx, cy) in [0, 1]
#   [3]     normalised width  (duplicate kept for alignment)
#   [4:6]   normalised width & height
#   [6]     fill value (density)
#   [7:12]  one-hot layer encoding (5 channels)
GRAPH_NODE_DIM = 12
GRAPH_MAX_NODES = 128  # pad/truncate to fixed size for batching

# ---------------------------------------------------------------------------
# Synthetic data cache
# ---------------------------------------------------------------------------

_CACHE_DIR = pathlib.Path("fixtures/benchmark/cache")
_CACHE_FILE = _CACHE_DIR / "unet_synth.pt"


def _load_or_generate_data(
    n_train: int,
    n_val: int,
    img_size: int,
    seed: int,
    use_film: bool,
) -> tuple[
    torch.Tensor, torch.Tensor, torch.Tensor, torch.Tensor,
    "torch.Tensor | None", "torch.Tensor | None",
]:
    """Load cached synthetic data or generate and save it.

    The cache key includes ``(n_train, n_val, img_size, seed, use_film)``
    so stale caches are automatically regenerated when parameters change.

    Returns:
        (X_train, Y_train, X_val, Y_val, G_train, G_val) where G_* are
        ``None`` when ``use_film`` is False.
    """
    cache_key = (n_train, n_val, img_size, seed, use_film)

    if _CACHE_FILE.exists():
        try:
            cached = torch.load(_CACHE_FILE, map_location="cpu", weights_only=True)
            if cached.get("key") == cache_key:
                logger.info("Loaded cached synthetic data from %s", _CACHE_FILE)
                return (
                    cached["X_train"], cached["Y_train"],
                    cached["X_val"], cached["Y_val"],
                    cached.get("G_train"), cached.get("G_val"),
                )
            else:
                logger.info("Cache key mismatch -- regenerating data.")
        except Exception as exc:  # noqa: BLE001
            logger.warning("Failed to load cache (%s) -- regenerating.", exc)

    # --- Generate fresh data ---
    logger.info("Generating %d+%d synthetic DRC samples (may be slow)...", n_train, n_val)
    X_train, Y_train = generate_drc_training_data(n_train, img_size, seed=seed)
    X_val, Y_val = generate_drc_training_data(n_val, img_size, seed=seed + 99999)

    G_train: torch.Tensor | None = None
    G_val: torch.Tensor | None = None
    if use_film:
        G_train = generate_graph_features(n_train, img_size, seed=seed)
        G_val = generate_graph_features(n_val, img_size, seed=seed + 99999)

    # --- Persist to cache ---
    try:
        _CACHE_DIR.mkdir(parents=True, exist_ok=True)
        payload: dict[str, Any] = {
            "key": cache_key,
            "X_train": X_train, "Y_train": Y_train,
            "X_val": X_val, "Y_val": Y_val,
        }
        if G_train is not None:
            payload["G_train"] = G_train
            payload["G_val"] = G_val
        torch.save(payload, _CACHE_FILE)
        logger.info("Saved synthetic data cache to %s", _CACHE_FILE)
    except OSError as exc:
        logger.warning("Could not write cache file: %s", exc)

    return X_train, Y_train, X_val, Y_val, G_train, G_val


def generate_graph_features(
    n_samples: int,
    img_size: int = IMG_SIZE,
    seed: int = 42,
    max_nodes: int = GRAPH_MAX_NODES,
) -> torch.Tensor:
    """Generate synthetic graph-level node features alongside layout images.

    Each "graph" corresponds to the set of rectangles placed in the matching
    synthetic layout sample.  Node features encode the device type, position,
    size and layer for every rectangle, mirroring the information that a real
    circuit netlist graph would carry.

    The random seed matches ``generate_drc_training_data`` so that the
    rectangle placements are identical -- we replay the same RNG sequence.

    Args:
        n_samples: Number of samples (must match ``generate_drc_training_data``).
        img_size:  Spatial resolution (used for normalisation).
        seed:      Random seed (must match the data generator).
        max_nodes: Fixed node count per graph (zero-padded / truncated).

    Returns:
        (n_samples, max_nodes, GRAPH_NODE_DIM) float32 tensor.
    """
    MIN_SPACING = 8
    MIN_WIDTH = 4
    VIA_ENCLOSURE = 3

    rng = np.random.default_rng(seed)
    graphs = np.zeros((n_samples, max_nodes, GRAPH_NODE_DIM), dtype=np.float32)

    for i in range(n_samples):
        node_idx = 0

        # --- Replay the same rectangle placement as generate_drc_training_data ---
        for ch in range(IN_CHANNELS):
            n_rects = rng.integers(5, 25)
            for _ in range(n_rects):
                w = rng.integers(3, min(50, img_size // 4))
                h = rng.integers(3, min(50, img_size // 4))
                x0 = rng.integers(0, max(1, img_size - w))
                y0 = rng.integers(0, max(1, img_size - h))
                val = rng.uniform(0.6, 1.0)

                if node_idx < max_nodes:
                    cx = (x0 + w / 2.0) / img_size
                    cy = (y0 + h / 2.0) / img_size
                    nw = w / img_size
                    nh = h / img_size
                    graphs[i, node_idx, 0] = float(ch)       # device/layer type
                    graphs[i, node_idx, 1] = cx               # centre x
                    graphs[i, node_idx, 2] = cy               # centre y
                    graphs[i, node_idx, 3] = nw               # normalised width
                    graphs[i, node_idx, 4] = nw               # width (dup)
                    graphs[i, node_idx, 5] = nh               # height
                    graphs[i, node_idx, 6] = val              # fill density
                    # One-hot layer encoding in indices 7..11.
                    graphs[i, node_idx, 7 + ch] = 1.0
                    node_idx += 1

        # --- Replay forced-spacing placements (keep RNG in sync) ---
        n_forced = rng.integers(2, 8)
        for _ in range(n_forced):
            _ch = rng.integers(0, IN_CHANNELS)
            _w1 = rng.integers(MIN_WIDTH, 30)
            _h1 = rng.integers(MIN_WIDTH, 30)
            _x1 = rng.integers(0, max(1, img_size - _w1 - MIN_SPACING - 30))
            _y1 = rng.integers(0, max(1, img_size - max(_h1, 30)))
            _val1 = rng.uniform(0.6, 1.0)
            _gap = rng.integers(1, MIN_SPACING)
            _w2 = rng.integers(MIN_WIDTH, 30)
            _h2 = rng.integers(MIN_WIDTH, 30)
            _x2 = _x1 + _w1 + _gap
            _y2 = _y1 + rng.integers(-min(5, _h1 // 2), min(5, _h1 // 2) + 1)
            _y2 = max(0, min(img_size - _h2, _y2))
            if _x2 + _w2 <= img_size and _y2 + _h2 <= img_size:
                _val2 = rng.uniform(0.6, 1.0)

        # --- Replay narrow-rectangle placements ---
        n_narrow = rng.integers(2, 6)
        for _ in range(n_narrow):
            _ch = rng.integers(0, IN_CHANNELS)
            if rng.random() < 0.5:
                _w = rng.integers(1, MIN_WIDTH)
                _h = rng.integers(MIN_WIDTH, 40)
            else:
                _w = rng.integers(MIN_WIDTH, 40)
                _h = rng.integers(1, MIN_WIDTH)
            _x0 = rng.integers(0, max(1, img_size - max(_w, 1)))
            _y0 = rng.integers(0, max(1, img_size - max(_h, 1)))
            _val = rng.uniform(0.6, 1.0)

        # --- Replay via placements ---
        n_vias = rng.integers(3, 10)
        for _ in range(n_vias):
            _via_size = rng.integers(3, 8)
            _vx = rng.integers(VIA_ENCLOSURE, max(VIA_ENCLOSURE + 1, img_size - _via_size - VIA_ENCLOSURE))
            _vy = rng.integers(VIA_ENCLOSURE, max(VIA_ENCLOSURE + 1, img_size - _via_size - VIA_ENCLOSURE))
            if rng.random() < 0.4:
                _enc = rng.integers(0, VIA_ENCLOSURE)
                _val_m1 = rng.uniform(0.6, 1.0)
                _val_m2 = rng.uniform(0.6, 1.0)
            else:
                _val_m1 = rng.uniform(0.6, 1.0)
                _val_m2 = rng.uniform(0.6, 1.0)

    return torch.from_numpy(graphs)


# ---------------------------------------------------------------------------
# Augmentation
# ---------------------------------------------------------------------------


def augment_batch(
    images: torch.Tensor,
    targets: torch.Tensor,
    noise_std: float = 0.03,
    channel_dropout_p: float = 0.1,
    jitter_range: float = 0.1,
) -> tuple[torch.Tensor, torch.Tensor]:
    """Apply D4 geometric augmentation plus photometric perturbations.

    Geometric transforms (rotation, flip) are applied to both images and
    targets so they stay spatially aligned.  Photometric perturbations
    (Gaussian noise, channel dropout, intensity jitter) only affect the
    input images -- targets are left untouched.

    Args:
        images: (B, C, H, W) layout images.
        targets: (B, 1, H, W) violation masks.
        noise_std: Standard deviation of additive Gaussian noise.
        channel_dropout_p: Per-channel probability of zeroing out a channel.
        jitter_range: Maximum absolute shift for per-channel intensity jitter.

    Returns:
        (augmented_images, augmented_targets).
    """
    B, C = images.shape[0], images.shape[1]
    aug_img = images.clone()
    aug_tgt = targets.clone()

    # --- D4 geometric transforms (applied to both images and targets) ---
    for b in range(B):
        k = torch.randint(0, 4, (1,)).item()
        aug_img[b] = torch.rot90(aug_img[b], k, dims=(-2, -1))
        aug_tgt[b] = torch.rot90(aug_tgt[b], k, dims=(-2, -1))
        if torch.rand(1).item() > 0.5:
            aug_img[b] = torch.flip(aug_img[b], dims=(-1,))
            aug_tgt[b] = torch.flip(aug_tgt[b], dims=(-1,))
        if torch.rand(1).item() > 0.5:
            aug_img[b] = torch.flip(aug_img[b], dims=(-2,))
            aug_tgt[b] = torch.flip(aug_tgt[b], dims=(-2,))

    # --- Photometric perturbations (images only, targets unaffected) ---

    # Gaussian noise.
    if noise_std > 0:
        aug_img = aug_img + torch.randn_like(aug_img) * noise_std

    # Channel dropout: independently zero out each channel with probability p.
    if channel_dropout_p > 0:
        mask = (torch.rand(B, C, 1, 1, device=aug_img.device) > channel_dropout_p).float()
        aug_img = aug_img * mask

    # Intensity jitter: per-channel additive shift.
    if jitter_range > 0:
        jitter = (torch.rand(B, C, 1, 1, device=aug_img.device) - 0.5) * 2.0 * jitter_range
        aug_img = aug_img + jitter

    # Clamp to valid range.
    aug_img = aug_img.clamp(0.0, 1.0)

    return aug_img, aug_tgt


# ---------------------------------------------------------------------------
# Training
# ---------------------------------------------------------------------------


def train(
    *,
    n_samples: int = 500,
    epochs: int = 100,
    batch_size: int = 8,
    lr: float = 1e-3,
    weight_decay: float = 1e-4,
    patience: int = 20,
    val_fraction: float = 0.2,
    device: str | torch.device = "cpu",
    checkpoint_dir: str | pathlib.Path = "checkpoints/unet",
    verbose: bool = True,
    seed: int = 42,
    use_film: bool = False,
    use_tta: bool = True,
    swa_epochs: int = 20,
    morph_cleanup: bool = True,
    viz: Any = None,
) -> dict[str, Any]:
    """Full training loop with early stopping on validation F1.

    Args:
        use_film: When True, generate graph features for each sample and
            apply FiLM (Feature-wise Linear Modulation) conditioning at
            the UNet bottleneck via a :class:`GraphConditioner`.
        use_tta: When True, use D4 Test-Time Augmentation during
            validation.  All 8 D4 transforms are applied, predictions
            are inverse-transformed and averaged in probability space.
            Disabled during training (training augmentation is separate).
        swa_epochs: Number of Stochastic Weight Averaging epochs to run
            after the main training loop finishes.  Set to 0 to disable.
        morph_cleanup: When True, apply morphological post-processing
            (opening + small-component removal) to predicted violation
            masks during validation.  Reports both raw and post-processed
            F1 in logs.

    Returns a dict with training history and best F1 score.
    """
    device = torch.device(device)
    checkpoint_dir = pathlib.Path(checkpoint_dir)
    checkpoint_dir.mkdir(parents=True, exist_ok=True)

    # --- Generate (or load cached) data ---
    n_val = max(1, int(n_samples * val_fraction))
    n_train = n_samples - n_val

    X_train, Y_train, X_val, Y_val, G_train, G_val = _load_or_generate_data(
        n_train, n_val, IMG_SIZE, seed, use_film,
    )

    viol_ratio_train = Y_train.mean().item()
    viol_ratio_val = Y_val.mean().item()
    logger.info(
        "Train: %d samples (%.2f%% violation pixels), Val: %d samples (%.2f%% violation pixels)",
        n_train, viol_ratio_train * 100, n_val, viol_ratio_val * 100,
    )

    # DataLoader kwargs: use workers + pinned memory when on CUDA.
    _on_cuda = "cuda" in str(device)
    _loader_kwargs: dict[str, Any] = {}
    if _on_cuda:
        _loader_kwargs.update(num_workers=4, pin_memory=True)

    if use_film and G_train is not None:
        train_loader = DataLoader(
            TensorDataset(X_train, Y_train, G_train),
            batch_size=batch_size, shuffle=True, **_loader_kwargs,
        )
        val_loader = DataLoader(
            TensorDataset(X_val, Y_val, G_val),
            batch_size=batch_size, shuffle=False, **_loader_kwargs,
        )
    else:
        train_loader = DataLoader(
            TensorDataset(X_train, Y_train),
            batch_size=batch_size, shuffle=True, **_loader_kwargs,
        )
        val_loader = DataLoader(
            TensorDataset(X_val, Y_val),
            batch_size=batch_size, shuffle=False, **_loader_kwargs,
        )

    # --- Model / optim ---
    film_cond_dim = 64
    model = build_model(
        device=device,
        use_checkpointing=True,
        use_film=use_film,
        film_cond_dim=film_cond_dim,
    )
    total_params = sum(p.numel() for p in model.parameters())
    logger.info("Model parameters: %s", f"{total_params:,}")

    # --- Deep supervision: auxiliary heads on the 2 finest decoder levels ---
    # dec1 outputs base_features (64) channels, dec2 outputs base_features*2 (128).
    _base_model_ref = getattr(model, "_orig_mod", model)
    _f = _base_model_ref.enc1.conv.block[0].out_channels  # base_features
    aux_head_1 = nn.Conv2d(_f, 1, 1).to(device)        # finest (dec1 output)
    aux_head_2 = nn.Conv2d(_f * 2, 1, 1).to(device)    # second-finest (dec2 output)
    aux_head_3 = nn.Conv2d(_f * 4, 1, 1).to(device)    # third-finest (dec3 output)
    nn.init.kaiming_normal_(aux_head_1.weight, nonlinearity="relu")
    nn.init.zeros_(aux_head_1.bias)
    nn.init.kaiming_normal_(aux_head_2.weight, nonlinearity="relu")
    nn.init.zeros_(aux_head_2.bias)
    nn.init.kaiming_normal_(aux_head_3.weight, nonlinearity="relu")
    nn.init.zeros_(aux_head_3.bias)

    # Storage for intermediate decoder features captured by forward hooks.
    _deep_sup_features: dict[str, torch.Tensor] = {}

    def _hook_dec1(module, input, output):  # noqa: A002
        _deep_sup_features["dec1"] = output

    def _hook_dec2(module, input, output):  # noqa: A002
        _deep_sup_features["dec2"] = output

    def _hook_dec3(module, input, output):  # noqa: A002
        _deep_sup_features["dec3"] = output

    _base_model_ref.dec1.register_forward_hook(_hook_dec1)
    _base_model_ref.dec2.register_forward_hook(_hook_dec2)
    _base_model_ref.dec3.register_forward_hook(_hook_dec3)
    logger.info("Deep supervision: auxiliary heads on dec1 (%d ch), dec2 (%d ch), dec3 (%d ch).", _f, _f * 2, _f * 4)

    # torch.compile for graph-level kernel fusion (PyTorch 2+).
    # Only enable on CUDA where inductor provides real speedups; on CPU the
    # compilation overhead and potential C++ compiler issues are not worth it.
    if _on_cuda and hasattr(torch, "compile"):
        try:
            model = torch.compile(model)
            logger.info("torch.compile enabled.")
        except Exception as exc:  # noqa: BLE001
            logger.warning("torch.compile failed (%s) -- falling back to eager.", exc)

    # Build the graph conditioner when using FiLM.
    graph_cond_net: GraphConditioner | None = None
    if use_film:
        graph_cond_net = GraphConditioner(
            node_dim=GRAPH_NODE_DIM, hidden=64, out_dim=film_cond_dim,
        ).to(device)
        cond_params = sum(p.numel() for p in graph_cond_net.parameters())
        logger.info("GraphConditioner parameters: %s", f"{cond_params:,}")
        logger.info("FiLM overhead: %s", f"{total_params - sum(p.numel() for p in build_model(device='cpu').parameters()) + cond_params:,}")

    # Mixed-precision (AMP) -- significant speedup for 31M params on 512x512.
    use_amp = _on_cuda
    scaler = torch.amp.GradScaler("cuda", enabled=use_amp)
    if use_amp:
        logger.info("Mixed-precision training (AMP) enabled.")

    # Collect all trainable parameters (UNet + aux heads + optional conditioner).
    all_params = list(model.parameters())
    all_params += list(aux_head_1.parameters())
    all_params += list(aux_head_2.parameters())
    all_params += list(aux_head_3.parameters())
    if graph_cond_net is not None:
        all_params += list(graph_cond_net.parameters())

    optimiser = torch.optim.AdamW(all_params, lr=lr, weight_decay=weight_decay)
    scheduler = torch.optim.lr_scheduler.ReduceLROnPlateau(
        optimiser, mode="max", factor=0.5, patience=patience // 3, min_lr=1e-6,
    )

    # --- Training loop ---
    best_val_f1 = -1.0
    epochs_no_improve = 0
    history: dict[str, list[float]] = {
        "train_loss": [],
        "val_loss": [],
        "val_f1": [],
        "val_precision": [],
        "val_recall": [],
        "val_auc": [],
    }

    for epoch in range(1, epochs + 1):
        # -- Train --
        model.train()
        if graph_cond_net is not None:
            graph_cond_net.train()
        running_loss = 0.0
        n_batch_samples = 0
        for batch_data in train_loader:
            if use_film and len(batch_data) == 3:
                batch_x, batch_y, batch_g = batch_data
                batch_g = batch_g.to(device)
            else:
                batch_x, batch_y = batch_data[0], batch_data[1]
                batch_g = None

            batch_x = batch_x.to(device)
            batch_y = batch_y.to(device)
            batch_x, batch_y = augment_batch(batch_x, batch_y)

            # Compute graph conditioning vector.
            graph_cond_vec = None
            if graph_cond_net is not None and batch_g is not None:
                graph_cond_vec = graph_cond_net(batch_g)

            optimiser.zero_grad()
            with torch.amp.autocast("cuda", enabled=use_amp):
                logits = model(batch_x, graph_cond=graph_cond_vec)
                loss = focal_tversky_loss(logits, batch_y)
                loss = loss + 0.1 * boundary_dou_loss(logits, batch_y)

                # Deep supervision: auxiliary losses on intermediate decoder outputs.
                if "dec2" in _deep_sup_features:
                    aux2_logits = aux_head_2(_deep_sup_features["dec2"])
                    target_ds2 = F.interpolate(
                        batch_y, size=aux2_logits.shape[2:],
                        mode="bilinear", align_corners=False,
                    )
                    loss = loss + 0.3 * focal_tversky_loss(aux2_logits, target_ds2)
                if "dec1" in _deep_sup_features:
                    aux1_logits = aux_head_1(_deep_sup_features["dec1"])
                    target_ds1 = F.interpolate(
                        batch_y, size=aux1_logits.shape[2:],
                        mode="bilinear", align_corners=False,
                    )
                    loss = loss + 0.3 * focal_tversky_loss(aux1_logits, target_ds1)
                if "dec3" in _deep_sup_features:
                    aux3_logits = aux_head_3(_deep_sup_features["dec3"])
                    target_ds3 = F.interpolate(
                        batch_y, size=aux3_logits.shape[2:],
                        mode="bilinear", align_corners=False,
                    )
                    loss = loss + 0.15 * focal_tversky_loss(aux3_logits, target_ds3)

            scaler.scale(loss).backward()
            scaler.step(optimiser)
            scaler.update()

            running_loss += loss.item() * batch_x.size(0)
            n_batch_samples += batch_x.size(0)

        train_loss = running_loss / max(n_batch_samples, 1)

        # -- Validate --
        model.eval()
        if graph_cond_net is not None:
            graph_cond_net.eval()
        val_loss_total = 0.0
        n_val_samples = 0
        # Accumulate predictions across batches.
        all_probs = []
        all_targets = []

        with torch.no_grad():
            for batch_data in val_loader:
                if use_film and len(batch_data) == 3:
                    batch_x, batch_y, batch_g = batch_data
                    batch_g = batch_g.to(device)
                else:
                    batch_x, batch_y = batch_data[0], batch_data[1]
                    batch_g = None

                batch_x = batch_x.to(device)
                batch_y = batch_y.to(device)

                # Compute graph conditioning vector.
                graph_cond_vec = None
                if graph_cond_net is not None and batch_g is not None:
                    graph_cond_vec = graph_cond_net(batch_g)

                with torch.amp.autocast("cuda", enabled=use_amp):
                    logits = model(batch_x, graph_cond=graph_cond_vec)
                    loss = focal_tversky_loss(logits, batch_y)
                val_loss_total += loss.item() * batch_x.size(0)
                n_val_samples += batch_x.size(0)

                # Use TTA or standard sigmoid for probability maps.
                if use_tta:
                    probs = predict_with_tta(
                        model, batch_x, graph_cond=graph_cond_vec,
                        use_amp=use_amp,
                    )
                else:
                    probs = torch.sigmoid(logits)

                all_probs.append(probs)
                all_targets.append(batch_y)

        val_loss = val_loss_total / max(n_val_samples, 1)

        # Compute metrics on entire validation set at once.
        # Sweep thresholds to find the one that maximises F1.
        all_probs_t = torch.cat(all_probs, dim=0)
        all_targets_t = torch.cat(all_targets, dim=0)
        best_metrics: dict[str, float] | None = None
        best_threshold = 0.5
        for thr in [0.1, 0.15, 0.2, 0.25, 0.3, 0.35, 0.4, 0.45, 0.5]:
            m = compute_metrics_from_probs(all_probs_t, all_targets_t, threshold=thr)
            if best_metrics is None or m["f1"] > best_metrics["f1"]:
                best_metrics = m
                best_threshold = thr
        assert best_metrics is not None
        metrics = best_metrics
        metrics["threshold"] = best_threshold

        # Morphological post-processing: compute cleaned metrics alongside raw.
        morph_f1 = metrics["f1"]
        if morph_cleanup:
            probs_np = all_probs_t.cpu().numpy()
            targets_np = all_targets_t.cpu().numpy()
            cleaned = apply_morphological_cleanup(probs_np, threshold=best_threshold)
            cleaned_t = torch.from_numpy(cleaned).to(all_targets_t.device)
            # cleaned_t is already binary; compute metrics at threshold=0.5.
            morph_metrics = compute_metrics_from_probs(cleaned_t, all_targets_t, threshold=0.5)
            morph_f1 = morph_metrics["f1"]
            metrics["morph_f1"] = morph_f1
            metrics["morph_precision"] = morph_metrics["precision"]
            metrics["morph_recall"] = morph_metrics["recall"]

        scheduler.step(metrics["f1"])

        history["train_loss"].append(train_loss)
        history["val_loss"].append(val_loss)
        history["val_f1"].append(metrics["f1"])
        history["val_precision"].append(metrics["precision"])
        history["val_recall"].append(metrics["recall"])

        # visualization
        if viz is not None:
            viz.update(epoch, {
                "train_loss": train_loss,
                "val_loss": val_loss,
                "val_f1": metrics["f1"],
                "val_auc": metrics["auc"],
            })
        history["val_auc"].append(metrics["auc"])

        if verbose and (epoch % 5 == 0 or epoch == 1):
            morph_str = ""
            if morph_cleanup:
                morph_str = f"  morph_F1={morph_f1:.4f}"
            logger.info(
                "Epoch %3d/%d  train_loss=%.5f  val_loss=%.5f  "
                "F1=%.4f  prec=%.4f  rec=%.4f  AUC=%.4f  thr=%.2f  lr=%.2e%s",
                epoch,
                epochs,
                train_loss,
                val_loss,
                metrics["f1"],
                metrics["precision"],
                metrics["recall"],
                metrics["auc"],
                metrics["threshold"],
                optimiser.param_groups[0]["lr"],
                morph_str,
            )

        # -- Checkpoint & early stopping (on val F1) --
        if metrics["f1"] > best_val_f1:
            best_val_f1 = metrics["f1"]
            epochs_no_improve = 0
            # Use the unwrapped model for state_dict when torch.compile is active.
            _save_model = getattr(model, "_orig_mod", model)
            ckpt: dict[str, Any] = {
                "epoch": epoch,
                "model_state_dict": _save_model.state_dict(),
                "optimiser_state_dict": optimiser.state_dict(),
                "val_f1": metrics["f1"],
                "val_precision": metrics["precision"],
                "val_recall": metrics["recall"],
                "val_auc": metrics["auc"],
                "val_loss": val_loss,
                "use_film": use_film,
            }
            if graph_cond_net is not None:
                ckpt["graph_cond_state_dict"] = graph_cond_net.state_dict()
            torch.save(ckpt, checkpoint_dir / "best_model.pt")
        else:
            epochs_no_improve += 1
            if epochs_no_improve >= patience:
                logger.info(
                    "Early stopping at epoch %d (best F1=%.4f)",
                    epoch,
                    best_val_f1,
                )
                break

    # ------------------------------------------------------------------
    # Stochastic Weight Averaging (SWA) phase
    # ------------------------------------------------------------------
    if swa_epochs > 0:
        logger.info(
            "Starting SWA phase for %d epochs (swa_lr=%.2e) ...",
            swa_epochs, lr * 0.1,
        )

        # Reload the best checkpoint into the base model before SWA.
        _best_ckpt_path = checkpoint_dir / "best_model.pt"
        if _best_ckpt_path.exists():
            _best_ckpt = torch.load(
                _best_ckpt_path, map_location=device, weights_only=True,
            )
            _base_model = getattr(model, "_orig_mod", model)
            _base_model.load_state_dict(_best_ckpt["model_state_dict"])
            if graph_cond_net is not None and "graph_cond_state_dict" in _best_ckpt:
                graph_cond_net.load_state_dict(_best_ckpt["graph_cond_state_dict"])
            logger.info("Loaded best checkpoint (F1=%.4f) as SWA starting point.", best_val_f1)

        # Build the SWA averaged model.
        _base_model = getattr(model, "_orig_mod", model)
        swa_model = AveragedModel(_base_model)

        # Reset optimiser LR and create SWA scheduler.
        for pg in optimiser.param_groups:
            pg["lr"] = lr  # Reset to original LR before SWALR takes over.
        swa_scheduler = SWALR(optimiser, swa_lr=lr * 0.1)

        for swa_epoch in range(1, swa_epochs + 1):
            # -- SWA Train --
            _base_model.train()
            if graph_cond_net is not None:
                graph_cond_net.train()
            swa_running_loss = 0.0
            swa_n_samples = 0

            for batch_data in train_loader:
                if use_film and len(batch_data) == 3:
                    batch_x, batch_y, batch_g = batch_data
                    batch_g = batch_g.to(device)
                else:
                    batch_x, batch_y = batch_data[0], batch_data[1]
                    batch_g = None

                batch_x = batch_x.to(device)
                batch_y = batch_y.to(device)
                batch_x, batch_y = augment_batch(batch_x, batch_y)

                graph_cond_vec = None
                if graph_cond_net is not None and batch_g is not None:
                    graph_cond_vec = graph_cond_net(batch_g)

                optimiser.zero_grad()
                with torch.amp.autocast("cuda", enabled=use_amp):
                    logits = _base_model(batch_x, graph_cond=graph_cond_vec)
                    loss = focal_tversky_loss(logits, batch_y)
                    loss = loss + 0.1 * boundary_dou_loss(logits, batch_y)
                scaler.scale(loss).backward()
                scaler.step(optimiser)
                scaler.update()

                swa_running_loss += loss.item() * batch_x.size(0)
                swa_n_samples += batch_x.size(0)

            swa_model.update_parameters(_base_model)
            swa_scheduler.step()

            if verbose and (swa_epoch % 5 == 0 or swa_epoch == 1):
                swa_loss = swa_running_loss / max(swa_n_samples, 1)
                logger.info(
                    "SWA Epoch %3d/%d  train_loss=%.5f  lr=%.2e",
                    swa_epoch, swa_epochs, swa_loss,
                    optimiser.param_groups[0]["lr"],
                )

        # Update batch-norm statistics for the SWA model.
        logger.info("Updating SWA batch-norm statistics ...")
        update_bn(train_loader, swa_model, device=device)

        # Evaluate the SWA model on the validation set.
        swa_model.eval()
        if graph_cond_net is not None:
            graph_cond_net.eval()

        swa_all_probs = []
        swa_all_targets = []
        with torch.no_grad():
            for batch_data in val_loader:
                if use_film and len(batch_data) == 3:
                    batch_x, batch_y, batch_g = batch_data
                    batch_g = batch_g.to(device)
                else:
                    batch_x, batch_y = batch_data[0], batch_data[1]
                    batch_g = None

                batch_x = batch_x.to(device)
                batch_y = batch_y.to(device)

                graph_cond_vec = None
                if graph_cond_net is not None and batch_g is not None:
                    graph_cond_vec = graph_cond_net(batch_g)

                if use_tta:
                    probs = predict_with_tta(
                        swa_model, batch_x, graph_cond=graph_cond_vec,
                        use_amp=use_amp,
                    )
                else:
                    with torch.amp.autocast("cuda", enabled=use_amp):
                        logits = swa_model(batch_x, graph_cond=graph_cond_vec)
                    probs = torch.sigmoid(logits)

                swa_all_probs.append(probs)
                swa_all_targets.append(batch_y)

        swa_probs_t = torch.cat(swa_all_probs, dim=0)
        swa_targets_t = torch.cat(swa_all_targets, dim=0)

        swa_best_metrics: dict[str, float] | None = None
        swa_best_threshold = 0.5
        for thr in [0.1, 0.15, 0.2, 0.25, 0.3, 0.35, 0.4, 0.45, 0.5]:
            m = compute_metrics_from_probs(swa_probs_t, swa_targets_t, threshold=thr)
            if swa_best_metrics is None or m["f1"] > swa_best_metrics["f1"]:
                swa_best_metrics = m
                swa_best_threshold = thr
        assert swa_best_metrics is not None
        swa_f1 = swa_best_metrics["f1"]

        swa_morph_str = ""
        if morph_cleanup:
            swa_probs_np = swa_probs_t.cpu().numpy()
            swa_targets_np = swa_targets_t.cpu().numpy()
            swa_cleaned = apply_morphological_cleanup(swa_probs_np, threshold=swa_best_threshold)
            swa_cleaned_t = torch.from_numpy(swa_cleaned).to(swa_targets_t.device)
            swa_morph_metrics = compute_metrics_from_probs(swa_cleaned_t, swa_targets_t, threshold=0.5)
            swa_morph_str = f"  morph_F1={swa_morph_metrics['f1']:.4f}"

        logger.info(
            "SWA evaluation: F1=%.4f (thr=%.2f)  prec=%.4f  rec=%.4f  AUC=%.4f%s",
            swa_f1, swa_best_threshold,
            swa_best_metrics["precision"],
            swa_best_metrics["recall"],
            swa_best_metrics["auc"],
            swa_morph_str,
        )

        if swa_f1 > best_val_f1:
            logger.info(
                "SWA model improves F1: %.4f -> %.4f. Saving SWA checkpoint.",
                best_val_f1, swa_f1,
            )
            best_val_f1 = swa_f1
            swa_ckpt: dict[str, Any] = {
                "epoch": epoch + swa_epochs,
                "model_state_dict": swa_model.module.state_dict(),
                "optimiser_state_dict": optimiser.state_dict(),
                "val_f1": swa_f1,
                "val_precision": swa_best_metrics["precision"],
                "val_recall": swa_best_metrics["recall"],
                "val_auc": swa_best_metrics["auc"],
                "val_loss": 0.0,  # Not tracked for SWA eval.
                "use_film": use_film,
                "swa": True,
            }
            if graph_cond_net is not None:
                swa_ckpt["graph_cond_state_dict"] = graph_cond_net.state_dict()
            torch.save(swa_ckpt, checkpoint_dir / "best_model.pt")
        else:
            logger.info(
                "SWA model did not improve F1 (%.4f <= %.4f). Keeping original best.",
                swa_f1, best_val_f1,
            )

    return {
        "best_val_f1": best_val_f1,
        "epochs_trained": epoch,
        "history": history,
        "checkpoint": str(checkpoint_dir / "best_model.pt"),
        "use_film": use_film,
    }


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------


def main() -> None:
    """CLI entry point: parse arguments and launch the UNet training loop."""
    logging.basicConfig(level=logging.INFO, format="%(levelname)s: %(message)s")

    parser = argparse.ArgumentParser(description="Train UNet DRC Violation Heatmap Predictor")
    parser.add_argument("--n-samples", type=int, default=500)
    parser.add_argument("--epochs", type=int, default=100)
    parser.add_argument("--batch-size", type=int, default=4)
    parser.add_argument("--lr", type=float, default=1e-3)
    parser.add_argument("--patience", type=int, default=20)
    parser.add_argument("--device", type=str, default="cpu")
    parser.add_argument(
        "--checkpoint-dir", type=str, default="checkpoints/unet"
    )
    parser.add_argument(
        "--use-film",
        action=argparse.BooleanOptionalAction,
        default=True,
        help="Enable FiLM (Feature-wise Linear Modulation) graph conditioning "
             "at the UNet bottleneck (default: enabled).",
    )
    parser.add_argument(
        "--use-tta",
        action=argparse.BooleanOptionalAction,
        default=True,
        help="Enable D4 Test-Time Augmentation during validation. "
             "All 8 D4 transforms are applied and predictions averaged "
             "in probability space (default: enabled).",
    )
    parser.add_argument(
        "--swa-epochs",
        type=int,
        default=20,
        help="Number of Stochastic Weight Averaging epochs after the main "
             "training loop (default: 20, 0 to disable).",
    )
    parser.add_argument(
        "--morph-cleanup",
        action=argparse.BooleanOptionalAction,
        default=True,
        help="Apply morphological post-processing (opening + small-component "
             "removal) to validation predictions.  Reports both raw and "
             "post-processed F1 in logs (default: enabled).  "
             "Use --no-morph-cleanup to disable.",
    )
    # visualization
    parser.add_argument(
        "--viz",
        action="store_true",
        default=False,
        help="Enable training visualization (saves PNG plots; live window if DISPLAY is set).",
    )
    parser.add_argument(
        "--use-rl",
        action="store_true",
        help="After UNet training, also train the RL repair agent.",
    )
    args = parser.parse_args()

    # visualization
    _viz = None
    if args.viz and _TrainingVisualizer is not None:
        import os as _os
        _viz = _TrainingVisualizer(
            model_name="unet",
            metrics=["train_loss", "val_loss", "val_f1", "val_auc"],
            output_dir=args.checkpoint_dir,
            save_every=10,
            live=bool(_os.environ.get("DISPLAY") or _os.environ.get("WAYLAND_DISPLAY")),
        )

    result = train(
        n_samples=args.n_samples,
        epochs=args.epochs,
        batch_size=args.batch_size,
        lr=args.lr,
        patience=args.patience,
        device=args.device,
        checkpoint_dir=args.checkpoint_dir,
        use_film=args.use_film,
        use_tta=args.use_tta,
        swa_epochs=args.swa_epochs,
        morph_cleanup=args.morph_cleanup,
        viz=_viz,
    )

    # visualization
    if _viz is not None:
        _viz.finish()

    logger.info("Training complete. Best F1: %.4f", result["best_val_f1"])
    logger.info("Checkpoint saved to: %s", result["checkpoint"])

    if args.use_rl:
        logger.info("Training RL repair agent...")
        rl_result = train_rl_repair(device=args.device)
        logger.info(
            "RL training complete. Best avg reward: %.1f",
            rl_result["best_avg_reward"],
        )
        logger.info("RL checkpoint: %s", rl_result["checkpoint"])


# ---------------------------------------------------------------------------
# Inference bridge -- called from pipeline.py
# ---------------------------------------------------------------------------

# Default checkpoint path relative to the project root.
_DEFAULT_CHECKPOINT = "checkpoints/unet/best_model.pt"


def _find_checkpoint() -> pathlib.Path:
    """Locate the UNet model checkpoint, searching from this file upward.

    Returns:
        Path to the checkpoint file (may not exist if not yet trained).
    """
    current = pathlib.Path(__file__).resolve().parent
    for _ in range(10):
        candidate = current / _DEFAULT_CHECKPOINT
        if candidate.exists():
            return candidate
        if (current / "build.zig").exists():
            return candidate
        parent = current.parent
        if parent == current:
            break
        current = parent
    return pathlib.Path(_DEFAULT_CHECKPOINT)


def _rasterize_positions(
    positions: np.ndarray,
    drc_data: list[dict],
    img_size: int = IMG_SIZE,
) -> tuple[np.ndarray, float, float, float]:
    """Rasterize device positions and DRC context onto a 5-channel bitmap.

    Channel assignments:
        0: device density map (Gaussian splat at each device position)
        1: DRC violation heat map (Gaussian splat at each violation location)
        2: DRC violation severity (actual / required ratio)
        3: x-gradient of device positions
        4: y-gradient of device positions

    Returns:
        (image, x_offset, y_offset, scale): image is (1, 5, H, W) float32;
        x_offset, y_offset, scale are the coordinate transform parameters.
    """
    image = np.zeros((1, IN_CHANNELS, img_size, img_size), dtype=np.float32)

    if positions.shape[0] == 0:
        return image, 0.0, 0.0, 1.0

    # Compute bounding box with padding.
    x_min, y_min = positions.min(axis=0)
    x_max, y_max = positions.max(axis=0)
    span_x = max(float(x_max - x_min), 1e-6)
    span_y = max(float(y_max - y_min), 1e-6)
    pad_x = span_x * 0.1
    pad_y = span_y * 0.1
    x_offset = float(x_min) - pad_x
    y_offset = float(y_min) - pad_y
    scale = max(span_x + 2 * pad_x, span_y + 2 * pad_y)

    def _to_pixel(x: float, y: float) -> tuple[int, int]:
        px = int(((x - x_offset) / scale) * (img_size - 1))
        py = int(((y - y_offset) / scale) * (img_size - 1))
        px = max(0, min(img_size - 1, px))
        py = max(0, min(img_size - 1, py))
        return px, py

    sigma = max(2, img_size // 64)
    r = 3 * sigma

    # Channel 0: device density.
    for i in range(positions.shape[0]):
        px, py = _to_pixel(float(positions[i, 0]), float(positions[i, 1]))
        for dy in range(-r, r + 1):
            for dx in range(-r, r + 1):
                nx, ny = px + dx, py + dy
                if 0 <= nx < img_size and 0 <= ny < img_size:
                    val = np.exp(-0.5 * (dx * dx + dy * dy) / (sigma * sigma))
                    image[0, 0, ny, nx] += val

    # Channels 1-2: DRC violations.
    for v in drc_data:
        px, py = _to_pixel(float(v["x"]), float(v["y"]))
        for dy in range(-r, r + 1):
            for dx in range(-r, r + 1):
                nx, ny = px + dx, py + dy
                if 0 <= nx < img_size and 0 <= ny < img_size:
                    val = np.exp(-0.5 * (dx * dx + dy * dy) / (sigma * sigma))
                    image[0, 1, ny, nx] += val
                    required = float(v.get("required", 1.0))
                    actual = float(v.get("actual", 0.0))
                    severity = actual / required if required > 0 else 1.0
                    image[0, 2, ny, nx] = max(image[0, 2, ny, nx], severity * val)

    # Channels 3-4: position gradients.
    for i in range(positions.shape[0]):
        px, py = _to_pixel(float(positions[i, 0]), float(positions[i, 1]))
        norm_x = (float(positions[i, 0]) - x_offset) / scale
        norm_y = (float(positions[i, 1]) - y_offset) / scale
        image[0, 3, py, px] = norm_x
        image[0, 4, py, px] = norm_y

    # Normalize density channels to [0, 1].
    for ch in [0, 1]:
        ch_max = image[0, ch].max()
        if ch_max > 0:
            image[0, ch] /= ch_max

    return image, x_offset, y_offset, scale


def _extract_correction_vectors(
    heatmap: np.ndarray,
    positions: np.ndarray,
    x_offset: float,
    y_offset: float,
    scale: float,
    img_size: int = IMG_SIZE,
    threshold: float = 0.5,
) -> np.ndarray:
    """Convert violation heatmap to per-device correction vectors.

    For each device, examine the local violation heatmap gradient at the
    device's pixel location.  The gradient of the sigmoid heatmap indicates
    the direction of increasing violation probability, so we push the device
    in the *opposite* direction (away from violations).

    Args:
        heatmap: (1, 1, H, W) violation probability map (after sigmoid).
        positions: (N, 2) device positions in physical coordinates.
        x_offset, y_offset, scale: coordinate transform from rasterization.
        img_size: image spatial resolution.
        threshold: only produce corrections where heatmap > threshold.

    Returns:
        (N, 2) correction deltas in physical coordinates.
    """
    num_devices = positions.shape[0]
    deltas = np.zeros((num_devices, 2), dtype=np.float32)

    if num_devices == 0:
        return deltas

    hm = heatmap[0, 0]  # (H, W)

    # Compute spatial gradients of the heatmap.
    # grad_x[y, x] ~ hm[y, x+1] - hm[y, x-1], grad_y similar.
    grad_x = np.zeros_like(hm)
    grad_y = np.zeros_like(hm)
    grad_x[:, 1:-1] = (hm[:, 2:] - hm[:, :-2]) / 2.0
    grad_y[1:-1, :] = (hm[2:, :] - hm[:-2, :]) / 2.0

    pixel_to_phys = scale / (img_size - 1)

    for i in range(num_devices):
        x = float(positions[i, 0])
        y = float(positions[i, 1])
        px = int(((x - x_offset) / scale) * (img_size - 1))
        py = int(((y - y_offset) / scale) * (img_size - 1))
        px = max(0, min(img_size - 1, px))
        py = max(0, min(img_size - 1, py))

        # Only correct if there is a violation nearby.
        if hm[py, px] > threshold:
            # Push away from violation gradient (negative gradient direction).
            gx = float(grad_x[py, px])
            gy = float(grad_y[py, px])
            mag = math.sqrt(gx * gx + gy * gy) + 1e-8
            # Scale correction proportional to violation intensity.
            correction_strength = float(hm[py, px]) * pixel_to_phys * 5.0
            deltas[i, 0] = -gx / mag * correction_strength
            deltas[i, 1] = -gy / mag * correction_strength

    return deltas


def predict_repair(
    positions: np.ndarray,
    drc_data: list[dict],
    use_rl: bool = False,
) -> np.ndarray:
    """Predict position repair deltas using the trained UNet violation heatmap model.

    Pipeline:
        1. Rasterize layout (device positions + DRC context) to 5-channel image.
        2. Run UNet to get violation heatmap logits.
        3. Apply sigmoid to get violation probabilities.
        4. Compute correction vectors from heatmap gradient at each device.
        5. (Optional) Refine corrections with the RL repair agent.

    Args:
        positions: (N, 2) float32 device positions (x, y).
        drc_data: List of dicts from ``SpoutFFI.get_drc_violations()``.
        use_rl: If True, run the RL repair agent on top of the
                gradient-based corrections for fine-grained refinement.

    Returns:
        (N, 2) float32 (dx, dy) repair deltas.

    Raises:
        FileNotFoundError: If the checkpoint file does not exist.
        RuntimeError: If model loading or inference fails.
    """
    num_devices = positions.shape[0] if positions.ndim >= 1 else 0

    if num_devices == 0:
        return np.zeros((0, 2), dtype=np.float32)

    # --- Load checkpoint ---
    ckpt_path = _find_checkpoint()
    if not ckpt_path.exists():
        raise FileNotFoundError(
            f"UNet model checkpoint not found at {ckpt_path}"
        )

    device = torch.device("cuda" if torch.cuda.is_available() else "cpu")
    ckpt = torch.load(ckpt_path, map_location=device, weights_only=True)

    model = build_model(device=device)
    model.load_state_dict(ckpt["model_state_dict"])
    model.eval()

    # --- Rasterize ---
    input_image, x_offset, y_offset, scale = _rasterize_positions(
        positions, drc_data
    )

    input_tensor = torch.from_numpy(input_image).to(device)

    # --- Inference: get violation heatmap ---
    with torch.no_grad():
        logits = model(input_tensor)
        heatmap = torch.sigmoid(logits)

    heatmap_np = heatmap.cpu().numpy()

    # --- Morphological post-processing ---
    heatmap_cleaned = apply_morphological_cleanup(heatmap_np, threshold=0.5)
    # Use cleaned mask for correction vectors; keep raw heatmap for RL.
    correction_heatmap = heatmap_np.copy()
    correction_heatmap[heatmap_cleaned < 0.5] = 0.0

    # --- Convert heatmap to position correction vectors ---
    deltas = _extract_correction_vectors(
        correction_heatmap, positions, x_offset, y_offset, scale
    )

    n_violations = int((heatmap_cleaned > 0.5).sum())
    logger.info(
        "predict_repair: %d devices, %d input violations, %d predicted violation pixels -> deltas %s",
        num_devices, len(drc_data), n_violations, deltas.shape,
    )

    # --- Optional RL refinement ---
    if use_rl and n_violations > 0:
        try:
            # Build device features from DRC data: (width, height, type).
            # Use approximate sizes from the rasterization scale.
            pixel_to_phys = scale / (IMG_SIZE - 1)
            dev_feats = []
            for i in range(num_devices):
                # Default device size estimate from rasterization.
                w = 5.0 * pixel_to_phys
                h = 5.0 * pixel_to_phys
                dev_type = 0
                dev_feats.append((w, h, dev_type))

            # Apply gradient-based deltas first, then refine with RL.
            corrected_positions = positions + deltas

            heatmap_2d = heatmap_np[0, 0]  # (H, W)
            rl_positions, n_remaining = predict_rl_repair(
                device_positions=corrected_positions,
                device_features=dev_feats,
                heatmap=heatmap_2d,
                max_iterations=10,
                device=str(device),
            )

            # Convert RL output back to deltas relative to original positions.
            deltas = rl_positions - positions

            logger.info(
                "predict_repair (RL refinement): %d estimated violations remaining",
                n_remaining,
            )
        except (ImportError, FileNotFoundError) as exc:
            logger.warning(
                "RL repair agent not available, using gradient-only corrections: %s",
                exc,
            )

    return deltas


if __name__ == "__main__":
    main()
