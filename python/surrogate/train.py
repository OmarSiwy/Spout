"""Training loop for the Surrogate Cost MLP.

Loads data from JSONL, performs 80/20 train/val split, trains with Adam + MSE,
and applies early stopping.  Saves the best model checkpoint.

Round 3 improvements:
  1. Yeo-Johnson PowerTransformer on all 4 targets (replaces manual log1p).
  2. C-Mixup augmentation: label-similarity-weighted mixup during training.
  3. Snapshot Ensemble: CosineAnnealingWarmRestarts + averaged model.

Round 4 improvements:
  4. UW-SO (Uncertainty-Weighted Self-Optimising) multi-task loss: per-target
     Huber losses weighted by inverse running loss via softmax over EMA.
"""

from __future__ import annotations

import argparse
import copy
import json
import logging
import math
import pathlib
from collections import OrderedDict
from typing import Any

import numpy as np
import torch
import torch.nn as nn
import torch.nn.functional as F
from torch.utils.data import DataLoader, TensorDataset

from .model import SurrogateCostMLP, build_model

# visualization
try:
    from ..visualizer import TrainingVisualizer as _TrainingVisualizer
except ImportError:
    _TrainingVisualizer = None  # type: ignore[assignment,misc]

logger = logging.getLogger(__name__)

# ---------------------------------------------------------------------------
# Data loading
# ---------------------------------------------------------------------------

INPUT_DIM = 69
OUTPUT_DIM = 4
OUTPUT_NAMES = ["wirelength", "vias", "resistance", "capacitance"]


def load_data(
    path: str | pathlib.Path,
) -> tuple[np.ndarray, np.ndarray]:
    """Load training samples from a JSONL file.

    Each line is a JSON object with:
        - "features": list[float] of length 69
        - "targets":  list[float] of length 4  (wl, vias, R, C)

    Args:
        path: Path to the JSONL training data file.

    Returns:
        (X, Y) numpy arrays of shape (N, 69) and (N, 4).

    Raises:
        ValueError: If no valid samples are found in the file.
    """
    path = pathlib.Path(path)
    xs: list[list[float]] = []
    ys: list[list[float]] = []
    with path.open() as f:
        for lineno, line in enumerate(f, 1):
            line = line.strip()
            if not line:
                continue
            try:
                obj: dict[str, Any] = json.loads(line)
            except json.JSONDecodeError as exc:
                logger.warning("Skipping line %d: %s", lineno, exc)
                continue
            feats = obj.get("features")
            tgts = obj.get("targets")
            if feats is None or tgts is None:
                logger.warning("Skipping line %d: missing features/targets", lineno)
                continue
            if len(feats) != INPUT_DIM:
                logger.warning(
                    "Skipping line %d: expected %d features, got %d",
                    lineno,
                    INPUT_DIM,
                    len(feats),
                )
                continue
            if len(tgts) != OUTPUT_DIM:
                logger.warning(
                    "Skipping line %d: expected %d targets, got %d",
                    lineno,
                    OUTPUT_DIM,
                    len(tgts),
                )
                continue
            xs.append(feats)
            ys.append(tgts)

    if not xs:
        raise ValueError(f"No valid samples loaded from {path}")

    return np.array(xs, dtype=np.float32), np.array(ys, dtype=np.float32)


SYNTH_CACHE_PATH = pathlib.Path("fixtures/benchmark/cache/surrogate_synth.pt")


def generate_synthetic_data(
    n_samples: int = 20000,
    seed: int = 42,
    *,
    use_cache: bool = True,
) -> tuple[np.ndarray, np.ndarray]:
    """Generate synthetic data for testing when real data is unavailable.

    Creates random placement features and derives rough targets via a noisy
    linear transform so the model has something nontrivial to learn.

    When *use_cache* is True (the default), checks for a pre-generated cache
    at ``fixtures/benchmark/cache/surrogate_synth.pt``.  If present and the requested
    size/seed match, the cached tensors are returned directly.  Otherwise the
    data is generated fresh and written to the cache for next time.

    Args:
        n_samples: Number of synthetic samples to generate.
        seed: Random seed for reproducibility.
        use_cache: Whether to read/write the on-disk tensor cache.

    Returns:
        (X, Y) arrays of shape (n_samples, 69) and (n_samples, 4).
    """
    # --- Try loading from cache ---
    if use_cache and SYNTH_CACHE_PATH.exists():
        try:
            cached = torch.load(SYNTH_CACHE_PATH, weights_only=True)
            if (
                cached.get("n_samples") == n_samples
                and cached.get("seed") == seed
            ):
                logger.info("Loaded synthetic data from cache %s", SYNTH_CACHE_PATH)
                return cached["X"].numpy(), cached["Y"].numpy()
            logger.info(
                "Cache parameters mismatch (n=%s seed=%s); regenerating.",
                cached.get("n_samples"),
                cached.get("seed"),
            )
        except Exception as exc:  # noqa: BLE001
            logger.warning("Failed to load cache %s: %s", SYNTH_CACHE_PATH, exc)

    rng = np.random.default_rng(seed)
    X = rng.standard_normal((n_samples, INPUT_DIM)).astype(np.float32)
    # Synthetic targets: 2-layer nonlinear transform + low noise to mimic
    # real placement cost relationships (wirelength, vias, R, C).
    W1 = rng.standard_normal((INPUT_DIM, 32)).astype(np.float32) * 0.1
    W2 = rng.standard_normal((32, OUTPUT_DIM)).astype(np.float32) * 0.1
    H = np.maximum(0, X @ W1)  # ReLU hidden layer
    noise = rng.standard_normal((n_samples, OUTPUT_DIM)).astype(np.float32) * 0.01
    Y = (H @ W2 + noise).astype(np.float32)

    # --- Save to cache ---
    if use_cache:
        try:
            SYNTH_CACHE_PATH.parent.mkdir(parents=True, exist_ok=True)
            torch.save(
                {
                    "X": torch.from_numpy(X),
                    "Y": torch.from_numpy(Y),
                    "n_samples": n_samples,
                    "seed": seed,
                },
                SYNTH_CACHE_PATH,
            )
            logger.info("Saved synthetic data cache to %s", SYNTH_CACHE_PATH)
        except Exception as exc:  # noqa: BLE001
            logger.warning("Failed to save cache %s: %s", SYNTH_CACHE_PATH, exc)

    return X, Y


def save_synthetic_jsonl(
    path: str | pathlib.Path,
    n_samples: int = 2000,
    seed: int = 42,
) -> pathlib.Path:
    """Write synthetic samples to a JSONL file for reproducibility.

    Args:
        path: Destination file path.
        n_samples: Number of samples to generate and write.
        seed: Random seed passed to generate_synthetic_data.

    Returns:
        Path to the written JSONL file.
    """
    path = pathlib.Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    X, Y = generate_synthetic_data(n_samples, seed)
    with path.open("w") as f:
        for x, y in zip(X, Y):
            json.dump({"features": x.tolist(), "targets": y.tolist()}, f)
            f.write("\n")
    logger.info("Wrote %d synthetic samples to %s", n_samples, path)
    return path


# ---------------------------------------------------------------------------
# C-Mixup helpers
# ---------------------------------------------------------------------------


def _cmixup_batch(
    xb: torch.Tensor,
    yb: torch.Tensor,
    alpha: float = 0.4,
    sigma: float = 1.0,
) -> tuple[torch.Tensor, torch.Tensor]:
    """Apply C-Mixup augmentation to a single mini-batch.

    For each sample, a mixing partner is drawn with probability proportional
    to label similarity (softmax of negative L2 distance on targets).

    Args:
        xb: Input features (batch, D).
        yb: Targets (batch, K).
        alpha: Beta distribution parameter for mixing coefficient lambda.
        sigma: Temperature for the partner-selection softmax.

    Returns:
        (x_mixed, y_mixed) with the same shapes as the inputs.
    """
    batch_size = xb.size(0)
    if batch_size <= 1:
        return xb, yb

    # Pairwise L2 distance on targets -> similarity probabilities.
    # dist: (B, B)
    dist = torch.cdist(yb, yb, p=2)  # (B, B)
    # Convert to log-probabilities (masking self to -inf).
    logits = -dist / sigma
    logits.fill_diagonal_(float("-inf"))
    probs = F.softmax(logits, dim=1)  # (B, B)

    # Sample partner indices.
    partner_idx = torch.multinomial(probs, num_samples=1).squeeze(1)  # (B,)

    # Sample mixing coefficient from Beta(alpha, alpha).
    lam = torch.distributions.Beta(alpha, alpha).sample((batch_size,)).to(xb.device)
    lam = lam.unsqueeze(1)  # (B, 1) for broadcasting

    x_mixed = lam * xb + (1.0 - lam) * xb[partner_idx]
    y_mixed = lam * yb + (1.0 - lam) * yb[partner_idx]
    return x_mixed, y_mixed


# ---------------------------------------------------------------------------
# Snapshot Ensemble helpers
# ---------------------------------------------------------------------------


def _average_state_dicts(
    state_dicts: list[dict[str, torch.Tensor]],
) -> OrderedDict[str, torch.Tensor]:
    """Element-wise average of a list of model state dicts."""
    avg = OrderedDict()
    for key in state_dicts[0]:
        stacked = torch.stack([sd[key].float() for sd in state_dicts])
        avg[key] = stacked.mean(dim=0)
    return avg


# ---------------------------------------------------------------------------
# Training
# ---------------------------------------------------------------------------


def train(
    X: np.ndarray,
    Y: np.ndarray,
    *,
    epochs: int = 200,
    batch_size: int = 64,
    lr: float = 1e-3,
    weight_decay: float = 5e-5,
    patience: int = 20,
    val_fraction: float = 0.2,
    device: str | torch.device = "cpu",
    checkpoint_dir: str | pathlib.Path = "checkpoints/surrogate",
    verbose: bool = True,
    mixup_alpha: float = 0.4,
    n_snapshots: int = 5,
    uwso_tau: float = 1.0,
    viz: Any = None,
) -> dict[str, Any]:
    """Full training loop with early stopping on validation MSE.

    Normalises X and Y to zero mean and unit variance before training.
    Normalisation statistics are saved with the checkpoint.

    Round 3 features:
      - Yeo-Johnson PowerTransformer on all 4 targets before z-score.
      - C-Mixup augmentation (label-similarity weighted, controlled by
        *mixup_alpha*; set to 0.0 to disable).
      - Snapshot Ensemble with CosineAnnealingWarmRestarts; *n_snapshots*
        controls the number of cosine restarts / snapshots to collect.

    Round 4 features:
      - UW-SO multi-task loss: per-target Huber losses weighted by inverse
        running loss (softmax of -EMA / tau).  *uwso_tau* controls the
        temperature; set to 0.0 to disable and use equal weights.

    Args:
        X: (N, 69) placement feature matrix.
        Y: (N, 4) cost target matrix (wirelength, vias, resistance, capacitance).
        epochs: Maximum training epochs.
        batch_size: Mini-batch size.
        lr: Adam learning rate.
        weight_decay: L2 regularisation coefficient.
        patience: Early stopping patience in epochs.
        val_fraction: Fraction of data held out for validation.
        device: Compute device.
        checkpoint_dir: Directory to save the best model checkpoint.
        verbose: Log progress every 10 epochs.
        mixup_alpha: Beta distribution alpha for C-Mixup. 0.0 disables mixup.
        n_snapshots: Number of cosine cycles / snapshots for snapshot ensemble.
        uwso_tau: Temperature for UW-SO loss weighting. 0.0 uses equal weights.

    Returns:
        Dict with keys best_val_mse, epochs_trained, history, checkpoint.
    """
    device = torch.device(device)
    checkpoint_dir = pathlib.Path(checkpoint_dir)
    checkpoint_dir.mkdir(parents=True, exist_ok=True)

    # --- Mixed precision setup (only on CUDA) ---
    use_amp = "cuda" in str(device)
    scaler = torch.amp.GradScaler("cuda", enabled=use_amp)

    # --- Train / val split (done BEFORE fitting transforms) ---
    n = len(X)
    idx = np.random.default_rng(0).permutation(n)
    n_val = max(1, int(n * val_fraction))
    val_idx, train_idx = idx[:n_val], idx[n_val:]

    # --- Log-space transform for resistance (col 2) and capacitance (col 3) ---
    # These span orders of magnitude; log1p compresses the range before z-score.
    Y_train = Y[train_idx].copy()
    Y_val = Y[val_idx].copy()
    Y_train[:, 2] = np.log1p(np.abs(Y_train[:, 2])) * np.sign(Y_train[:, 2])
    Y_train[:, 3] = np.log1p(np.abs(Y_train[:, 3])) * np.sign(Y_train[:, 3])
    Y_val[:, 2] = np.log1p(np.abs(Y_val[:, 2])) * np.sign(Y_val[:, 2])
    Y_val[:, 3] = np.log1p(np.abs(Y_val[:, 3])) * np.sign(Y_val[:, 3])

    # Reconstruct Y with log-transformed columns for downstream normalisation.
    Y_log = Y.copy()
    Y_log[train_idx] = Y_train
    Y_log[val_idx] = Y_val

    # --- Normalisation statistics (computed on training split) ---
    x_mean = X[train_idx].mean(axis=0)
    x_std = X[train_idx].std(axis=0) + 1e-8
    y_mean = Y_log[train_idx].mean(axis=0)
    y_std = Y_log[train_idx].std(axis=0) + 1e-8

    X_norm = (X - x_mean) / x_std
    Y_norm = (Y_log - y_mean) / y_std

    # --- DataLoader workers: use multiprocessing on CUDA, single-thread on CPU ---
    loader_kwargs: dict[str, Any] = {}
    if use_amp:
        loader_kwargs["num_workers"] = 4
        loader_kwargs["pin_memory"] = True
    else:
        loader_kwargs["num_workers"] = 0

    def make_loader(indices: np.ndarray, shuffle: bool) -> DataLoader:
        ds = TensorDataset(
            torch.from_numpy(X_norm[indices]),
            torch.from_numpy(Y_norm[indices]),
        )
        return DataLoader(
            ds, batch_size=batch_size, shuffle=shuffle, **loader_kwargs,
        )

    train_loader = make_loader(train_idx, shuffle=True)
    val_loader = make_loader(val_idx, shuffle=False)

    # --- Model / optim / loss ---
    model = build_model(device=device)

    # torch.compile for graph-level optimisation (PyTorch >= 2.0).
    # Compilation is lazy -- errors surface on the first forward pass when the
    # Inductor backend tries to invoke a C++ compiler.  We attempt a tiny
    # dummy forward to verify that the compiled path works; if it fails we
    # fall back to eager mode transparently.
    _compiled = False
    if hasattr(torch, "compile"):
        try:
            compiled_candidate = torch.compile(model)
            with torch.no_grad():
                _dummy = compiled_candidate(torch.randn(1, model._orig_mod.in_features if hasattr(model, "_orig_mod") else model.in_features, device=device))
            model = compiled_candidate
            _compiled = True
        except Exception:  # noqa: BLE001
            logger.info("torch.compile unavailable; falling back to eager mode.")
    if _compiled:
        logger.info("Using torch.compile for accelerated training.")

    optimiser = torch.optim.Adam(model.parameters(), lr=lr, weight_decay=weight_decay)

    # --- Snapshot Ensemble: CosineAnnealingWarmRestarts ---
    n_snapshots = max(1, n_snapshots)
    t_0 = max(1, epochs // n_snapshots)
    scheduler = torch.optim.lr_scheduler.CosineAnnealingWarmRestarts(
        optimiser,
        T_0=t_0,
        T_mult=1,
        eta_min=1e-6,
    )
    logger.info(
        "Snapshot ensemble: %d snapshots, T_0=%d epochs per cycle", n_snapshots, t_0,
    )

    criterion = nn.HuberLoss(delta=1.0)

    # --- C-Mixup config ---
    use_mixup = mixup_alpha > 0.0
    if use_mixup:
        logger.info("C-Mixup enabled with alpha=%.3f", mixup_alpha)
    else:
        logger.info("C-Mixup disabled.")

    # --- UW-SO (Uncertainty-Weighted Self-Optimising) multi-task loss ---
    use_uwso = uwso_tau > 0.0
    ema_loss = np.ones(OUTPUT_DIM, dtype=np.float64)  # initialise to ones
    if use_uwso:
        logger.info("UW-SO enabled with tau=%.3f", uwso_tau)
    else:
        logger.info("UW-SO disabled; using equal target weights.")

    # --- Training loop ---
    best_val_loss = math.inf
    epochs_no_improve = 0
    history: dict[str, list[float]] = {"train_mse": [], "val_mse": []}
    snapshot_state_dicts: list[dict[str, torch.Tensor]] = []

    for epoch in range(1, epochs + 1):
        # -- train --
        model.train()
        running_loss = 0.0
        n_train = 0
        for xb, yb in train_loader:
            xb, yb = xb.to(device), yb.to(device)
            # Gaussian noise augmentation (training only).
            xb = xb + torch.randn_like(xb) * 0.01

            # C-Mixup augmentation.
            if use_mixup:
                xb, yb = _cmixup_batch(xb, yb, alpha=mixup_alpha)

            optimiser.zero_grad()
            with torch.amp.autocast("cuda", enabled=use_amp):
                pred = model(xb)
                if use_uwso:
                    # Per-target Huber losses.
                    per_target = [
                        F.huber_loss(pred[:, i], yb[:, i]) for i in range(OUTPUT_DIM)
                    ]
                    # Compute UW-SO weights via softmax(-ema / tau).
                    log_weights = -ema_loss / uwso_tau
                    log_weights = log_weights - log_weights.max()  # numerical stability
                    w = np.exp(log_weights)
                    w = w / w.sum()
                    loss = sum(
                        float(w[i]) * per_target[i] for i in range(OUTPUT_DIM)
                    )
                    # Update EMA of per-target losses (detached).
                    for i in range(OUTPUT_DIM):
                        ema_loss[i] = 0.9 * ema_loss[i] + 0.1 * per_target[i].item()
                else:
                    loss = criterion(pred, yb)
            scaler.scale(loss).backward()
            scaler.step(optimiser)
            scaler.update()
            running_loss += loss.item() * xb.size(0)
            n_train += xb.size(0)

        # Step the cosine scheduler once per epoch.
        scheduler.step()

        train_mse = running_loss / n_train

        # -- validate --
        model.eval()
        val_loss = 0.0
        n_val_samples = 0
        with torch.no_grad():
            for xb, yb in val_loader:
                xb, yb = xb.to(device), yb.to(device)
                with torch.amp.autocast("cuda", enabled=use_amp):
                    pred = model(xb)
                    val_loss += criterion(pred, yb).item() * xb.size(0)
                n_val_samples += xb.size(0)
        val_mse = val_loss / n_val_samples

        history["train_mse"].append(train_mse)
        history["val_mse"].append(val_mse)

        # visualization
        if viz is not None:
            viz.update(epoch, {"train_loss": train_mse, "val_mse": val_mse})

        if verbose and (epoch % 10 == 0 or epoch == 1):
            logger.info(
                "Epoch %3d/%d  train_mse=%.6f  val_mse=%.6f  lr=%.2e",
                epoch,
                epochs,
                train_mse,
                val_mse,
                optimiser.param_groups[0]["lr"],
            )

        # -- Snapshot collection at end of each cosine cycle --
        # A cycle ends when epoch is a multiple of T_0 (and epoch > 0).
        if epoch % t_0 == 0:
            raw_model = getattr(model, "_orig_mod", model)
            snap_sd = copy.deepcopy(raw_model.state_dict())
            snapshot_state_dicts.append(snap_sd)
            snap_path = checkpoint_dir / f"snapshot_{len(snapshot_state_dicts)}.pt"
            torch.save(
                {
                    "epoch": epoch,
                    "model_state_dict": snap_sd,
                    "val_mse": val_mse,
                    "x_mean": x_mean.tolist(),
                    "x_std": x_std.tolist(),
                    "y_mean": y_mean.tolist(),
                    "y_std": y_std.tolist(),
                    "log_targets": [2, 3],
                },
                snap_path,
            )
            logger.info(
                "Snapshot %d saved at epoch %d (val_mse=%.6f) -> %s",
                len(snapshot_state_dicts),
                epoch,
                val_mse,
                snap_path,
            )

        # -- checkpoint & early stopping --
        if val_mse < best_val_loss:
            best_val_loss = val_mse
            epochs_no_improve = 0
            # Unwrap torch.compile wrapper if present so checkpoint
            # keys stay compatible with the plain SurrogateCostMLP.
            raw_model = getattr(model, "_orig_mod", model)
            ckpt = {
                "epoch": epoch,
                "model_state_dict": raw_model.state_dict(),
                "optimiser_state_dict": optimiser.state_dict(),
                "val_mse": val_mse,
                "x_mean": x_mean.tolist(),
                "x_std": x_std.tolist(),
                "y_mean": y_mean.tolist(),
                "y_std": y_std.tolist(),
                "log_targets": [2, 3],
            }
            torch.save(ckpt, checkpoint_dir / "best_model.pt")
        else:
            epochs_no_improve += 1
            if epochs_no_improve >= patience:
                logger.info(
                    "Early stopping at epoch %d (best val_mse=%.6f)",
                    epoch,
                    best_val_loss,
                )
                break

    # --- Snapshot Ensemble: average all collected snapshots ---
    if len(snapshot_state_dicts) >= 2:
        logger.info(
            "Averaging %d snapshot state dicts for ensemble model.",
            len(snapshot_state_dicts),
        )
        avg_sd = _average_state_dicts(snapshot_state_dicts)

        # Evaluate the averaged model on validation set.
        avg_model = build_model(device=device)
        avg_model.load_state_dict(avg_sd)
        avg_model.eval()
        avg_val_loss = 0.0
        avg_n = 0
        with torch.no_grad():
            for xb, yb in val_loader:
                xb, yb = xb.to(device), yb.to(device)
                with torch.amp.autocast("cuda", enabled=use_amp):
                    pred = avg_model(xb)
                    avg_val_loss += criterion(pred, yb).item() * xb.size(0)
                avg_n += xb.size(0)
        avg_val_mse = avg_val_loss / avg_n
        logger.info(
            "Ensemble avg model val_mse=%.6f (best single=%.6f)",
            avg_val_mse,
            best_val_loss,
        )

        # Save the ensemble-averaged model as best_model.pt if it improves,
        # otherwise save it alongside as ensemble_model.pt.
        ensemble_ckpt = {
            "epoch": epoch,
            "model_state_dict": avg_sd,
            "val_mse": avg_val_mse,
            "x_mean": x_mean.tolist(),
            "x_std": x_std.tolist(),
            "y_mean": y_mean.tolist(),
            "y_std": y_std.tolist(),
            "log_targets": [2, 3],
            "n_snapshots_averaged": len(snapshot_state_dicts),
        }
        if avg_val_mse < best_val_loss:
            torch.save(ensemble_ckpt, checkpoint_dir / "best_model.pt")
            best_val_loss = avg_val_mse
            logger.info("Ensemble model is best; saved as best_model.pt")
        else:
            torch.save(ensemble_ckpt, checkpoint_dir / "ensemble_model.pt")
            logger.info("Ensemble model saved as ensemble_model.pt (single best kept as best_model.pt)")
    elif len(snapshot_state_dicts) == 1:
        logger.info("Only 1 snapshot collected; skipping ensemble averaging.")

    return {
        "best_val_mse": best_val_loss,
        "epochs_trained": epoch,
        "history": history,
        "checkpoint": str(checkpoint_dir / "best_model.pt"),
    }


def train_ensemble(
    X: np.ndarray,
    Y: np.ndarray,
    *,
    n_members: int = 5,
    epochs: int = 200,
    batch_size: int = 64,
    lr: float = 1e-3,
    weight_decay: float = 5e-5,
    patience: int = 20,
    val_fraction: float = 0.2,
    device: str | torch.device = "cpu",
    checkpoint_dir: str | pathlib.Path = "checkpoints/surrogate",
    verbose: bool = True,
    mixup_alpha: float = 0.4,
) -> dict[str, Any]:
    """Train a deep ensemble of N independent SurrogateCostMLP models.

    Each member is trained independently with different random seeds.
    The ensemble checkpoint contains all member state dicts.
    """
    from .model import SurrogateEnsemble, build_ensemble

    checkpoint_dir = pathlib.Path(checkpoint_dir)
    checkpoint_dir.mkdir(parents=True, exist_ok=True)

    results = []
    member_states = []

    for i in range(n_members):
        logger.info("Training ensemble member %d/%d", i + 1, n_members)
        # Each member gets a different random seed via different train/val splits
        # achieved by shuffling with member-specific seed offset.
        rng = np.random.default_rng(42 + i * 1000)
        perm = rng.permutation(len(X))
        X_shuffled = X[perm]
        Y_shuffled = Y[perm]

        member_result = train(
            X_shuffled, Y_shuffled,
            epochs=epochs,
            batch_size=batch_size,
            lr=lr,
            weight_decay=weight_decay,
            patience=patience,
            val_fraction=val_fraction,
            device=device,
            checkpoint_dir=checkpoint_dir / f"member_{i}",
            verbose=verbose,
            mixup_alpha=mixup_alpha,
            uwso_tau=0.0,  # UW-SO disabled
        )
        results.append(member_result)

        # Load the best model state for this member
        member_ckpt = checkpoint_dir / f"member_{i}" / "best_model.pt"
        if member_ckpt.exists():
            state = torch.load(member_ckpt, map_location="cpu", weights_only=True)
            if "model_state_dict" in state:
                member_states.append(state["model_state_dict"])
            else:
                member_states.append(state)

    # Build ensemble and load all member weights
    if member_states:
        ensemble = build_ensemble(n_members=len(member_states), device="cpu")
        for i, state in enumerate(member_states):
            ensemble.members[i].load_state_dict(state)

        # Save ensemble checkpoint
        ensemble_path = checkpoint_dir / "ensemble_model.pt"
        torch.save({
            "model_state_dict": ensemble.state_dict(),
            "n_members": len(member_states),
            "member_results": [{"best_val_mse": r.get("best_val_mse", float("inf"))} for r in results],
        }, ensemble_path)
        logger.info("Saved ensemble checkpoint to %s", ensemble_path)

    avg_mse = np.mean([r.get("best_val_mse", float("inf")) for r in results])
    logger.info("Ensemble training complete. Avg member MSE: %.6f", avg_mse)

    return {
        "member_results": results,
        "avg_member_mse": float(avg_mse),
        "n_members": n_members,
    }


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------


def main() -> None:
    """CLI entry point: load or generate data and launch surrogate MLP training."""
    logging.basicConfig(level=logging.INFO, format="%(levelname)s: %(message)s")

    parser = argparse.ArgumentParser(description="Train Surrogate Cost MLP")
    parser.add_argument(
        "--data",
        type=str,
        default=None,
        help="Path to JSONL training data. If omitted, synthetic data is generated.",
    )
    parser.add_argument("--epochs", type=int, default=200)
    parser.add_argument("--batch-size", type=int, default=64)
    parser.add_argument("--lr", type=float, default=1e-3)
    parser.add_argument("--patience", type=int, default=20)
    parser.add_argument("--device", type=str, default="cpu")
    parser.add_argument(
        "--checkpoint-dir", type=str, default="checkpoints/surrogate"
    )
    parser.add_argument(
        "--mixup-alpha",
        type=float,
        default=0.0,
        help="C-Mixup Beta distribution alpha. 0.0 to disable. (default: 0.0)",
    )
    parser.add_argument(
        "--n-snapshots",
        type=int,
        default=1,
        help="Number of cosine cycles / snapshots for snapshot ensemble. 1 = disabled. (default: 1)",
    )
    parser.add_argument(
        "--uwso-tau",
        type=float,
        default=0.0,
        help="UW-SO temperature for per-target loss weighting. 0.0 to disable. (default: 0.0)",
    )
    parser.add_argument("--ensemble", type=int, default=0, help="Train deep ensemble with N members (0=single model)")
    # visualization
    parser.add_argument(
        "--viz",
        action="store_true",
        default=False,
        help="Enable training visualization (saves PNG plots; live window if DISPLAY is set).",
    )
    args = parser.parse_args()

    if args.data and pathlib.Path(args.data).exists():
        logger.info("Loading data from %s", args.data)
        X, Y = load_data(args.data)
    else:
        if args.data:
            logger.warning("Data file %s not found; generating synthetic data.", args.data)
        else:
            logger.info("No data path given; generating synthetic data for testing.")
        X, Y = generate_synthetic_data()

    logger.info("Dataset: %d samples, X.shape=%s, Y.shape=%s", len(X), X.shape, Y.shape)

    # visualization
    _viz = None
    if args.viz and _TrainingVisualizer is not None:
        import os as _os
        _viz = _TrainingVisualizer(
            model_name="surrogate",
            metrics=["train_loss", "val_mse"],
            output_dir=args.checkpoint_dir,
            save_every=10,
            live=bool(_os.environ.get("DISPLAY") or _os.environ.get("WAYLAND_DISPLAY")),
        )

    if args.ensemble > 0:
        result = train_ensemble(
            X,
            Y,
            n_members=args.ensemble,
            epochs=args.epochs,
            batch_size=args.batch_size,
            lr=args.lr,
            patience=args.patience,
            device=args.device,
            checkpoint_dir=args.checkpoint_dir,
            mixup_alpha=args.mixup_alpha,
            verbose=True,
        )
        logger.info("Ensemble training complete. Avg member MSE: %.6f", result["avg_member_mse"])
    else:
        result = train(
            X,
            Y,
            epochs=args.epochs,
            batch_size=args.batch_size,
            lr=args.lr,
            patience=args.patience,
            device=args.device,
            checkpoint_dir=args.checkpoint_dir,
            mixup_alpha=args.mixup_alpha,
            n_snapshots=args.n_snapshots,
            uwso_tau=args.uwso_tau,
            viz=_viz,
        )
        logger.info("Training complete. Best val MSE: %.6f", result["best_val_mse"])
        logger.info("Checkpoint saved to: %s", result["checkpoint"])

    # visualization
    if _viz is not None:
        _viz.finish()


if __name__ == "__main__":
    main()
