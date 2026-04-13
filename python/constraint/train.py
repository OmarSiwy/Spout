"""Training loop for the GNN Constraint Predictor.

Self-supervised contrastive training on topology-aware synthetic circuit graphs.
Positive pairs (differential pairs, current mirrors, common-centroid groups) are
identifiable from graph TOPOLOGY (shared nets, terminal patterns), not from
device feature similarity alone.

The graph is device-only: edges connect devices that share a net, with edge
features encoding terminal-type information and the number of shared nets.
This avoids embedding collapse from zero-feature net nodes in bipartite graphs.

Primary metric: F1 score for constraint pair prediction (best over thresholds).
"""

from __future__ import annotations

import argparse
import logging
import math
import pathlib
from collections import defaultdict
from typing import Any, Callable

import numpy as np
import torch
import torch.nn as nn

from .model import (
    DEVICE_FEAT_DIM,
    ConstraintGraphSAGE,
    EdgeDecoder,
    build_model,
    contrastive_loss,
)

# visualization
try:
    from ..visualizer import TrainingVisualizer as _TrainingVisualizer
except ImportError:
    _TrainingVisualizer = None  # type: ignore[assignment,misc]


# ---------------------------------------------------------------------------
# Structural fingerprint -- topology-derived per-device features
# ---------------------------------------------------------------------------


def compute_structural_fingerprint(
    n_devices: int,
    pins: list[tuple[int, int, int]],
) -> np.ndarray:
    """Compute a 4-dim structural fingerprint per device from pin connectivity.

    Features:
        [0] diff_pair_candidate  -- shared source, different gates
        [1] mirror_candidate     -- shared gate with at least one diode-connected device
        [2] is_diode_connected   -- gate and drain on the same net
        [3] shared_gate_group    -- shares a gate net with another device

    Args:
        n_devices: Total number of devices.
        pins: List of (device_idx, net_idx, terminal_type) where
              terminal_type: 0=gate, 1=drain, 2=source.

    Returns:
        float32 array of shape (n_devices, 4).
    """
    GATE, DRAIN, SOURCE = 0, 1, 2
    net_pins: dict[int, list[tuple[int, int]]] = defaultdict(list)
    dev_pins: dict[int, list[tuple[int, int]]] = defaultdict(list)
    for dev, net, term in pins:
        net_pins[net].append((dev, term))
        dev_pins[dev].append((net, term))

    fp = np.zeros((n_devices, 4), dtype=np.float32)

    # is_diode_connected: gate and drain share a net.
    for dev in range(n_devices):
        gate_nets = {n for n, t in dev_pins[dev] if t == GATE}
        drain_nets = {n for n, t in dev_pins[dev] if t == DRAIN}
        if gate_nets & drain_nets:
            fp[dev, 2] = 1.0

    # diff pair candidates: shared source net, different gate nets.
    for net, devterms in net_pins.items():
        src_devs = [d for d, t in devterms if t == SOURCE]
        if len(src_devs) >= 2:
            for i in range(len(src_devs)):
                for j in range(i + 1, len(src_devs)):
                    ga = {n for n, t in dev_pins[src_devs[i]] if t == GATE}
                    gb = {n for n, t in dev_pins[src_devs[j]] if t == GATE}
                    if not (ga & gb):
                        fp[src_devs[i], 0] = 1.0
                        fp[src_devs[j], 0] = 1.0

    # mirror candidates: shared gate net with at least one diode-connected device.
    for net, devterms in net_pins.items():
        gate_devs = [d for d, t in devterms if t == GATE]
        if len(gate_devs) >= 2:
            has_diode = any(fp[d, 2] == 1.0 for d in gate_devs)
            if has_diode:
                for d in gate_devs:
                    fp[d, 1] = 1.0
            for d in gate_devs:
                fp[d, 3] = 1.0

    return fp


# ---------------------------------------------------------------------------
# Loss functions
# ---------------------------------------------------------------------------


def logistic_pairwise_loss(sim: torch.Tensor, label: torch.Tensor) -> torch.Tensor:
    """Logistic pairwise loss: sigmoid cross-entropy on similarity scores.

    Args:
        sim: Similarity scores (any shape).
        label: +1 for positive pairs, -1 for negative pairs (same shape as sim).

    Returns:
        Scalar mean loss.
    """
    return torch.log(1 + torch.exp(-label * sim)).mean()


def variance_regularizer(embeddings: torch.Tensor, gamma: float = 1.0) -> torch.Tensor:
    """VICReg variance regularizer: penalise dimensions with std < gamma.

    Prevents embedding collapse by encouraging each dimension to have
    sufficient variance across the batch.

    Args:
        embeddings: (N, D) embedding tensor.
        gamma: Target standard deviation threshold.

    Returns:
        Scalar penalty (mean over dimensions of relu(gamma - std)).
    """
    std = embeddings.std(dim=0)
    return torch.relu(gamma - std).mean()


logger = logging.getLogger(__name__)


# ---------------------------------------------------------------------------
# Learned threshold classifier -- pair-level MLP
# ---------------------------------------------------------------------------


class PairClassifier(nn.Module):
    """Small 3-layer MLP that classifies device pairs from hand-crafted features.

    Input features per pair (7 dims):
        [0] cosine_similarity        -- dot product of L2-normed embeddings
        [1] abs_degree_difference    -- |deg(a) - deg(b)| in the device graph
        [2] type_match_flag          -- 1.0 if both devices share the same type
        [3] structural_fp_l2_dist    -- L2 distance between structural fingerprints
        [4] hadamard_scalar          -- (emb_a * emb_b).sum()
        [5] l1_distance              -- (emb_a - emb_b).abs().sum()
        [6] norm_ratio               -- max(norm_a, norm_b) / (min(norm_a, norm_b) + 1e-8)

    Architecture: Linear(7, 32) -> ReLU -> Dropout(0.1) -> Linear(32, 16) -> ReLU -> Linear(16, 1) -> Sigmoid
    """

    def __init__(self) -> None:
        super().__init__()
        self.net = nn.Sequential(
            nn.Linear(7, 32),
            nn.ReLU(inplace=True),
            nn.Dropout(0.1),
            nn.Linear(32, 16),
            nn.ReLU(inplace=True),
            nn.Linear(16, 1),
        )

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        """Return probability that each pair is a constraint pair.

        Args:
            x: (K, 7) pair feature tensor.

        Returns:
            (K,) sigmoid probabilities.
        """
        return torch.sigmoid(self.net(x)).squeeze(-1)


def _compute_pair_features(
    embeddings: torch.Tensor,
    node_features: torch.Tensor,
    edge_index: torch.Tensor,
    pair_indices: torch.Tensor,
) -> torch.Tensor:
    """Build the 7-dim feature vector for each candidate pair.

    Args:
        embeddings: (N, D) L2-normalised device embeddings.
        node_features: (N, 16) raw device features (type one-hot + params + fp).
        edge_index: (2, E) COO edge index of the device graph.
        pair_indices: (K, 2) indices of pairs to featurise.

    Returns:
        (K, 7) float tensor of pair features.
    """
    dev = embeddings.device
    n = embeddings.size(0)
    k = pair_indices.size(0)

    a_idx = pair_indices[:, 0]
    b_idx = pair_indices[:, 1]

    emb_a = embeddings[a_idx]
    emb_b = embeddings[b_idx]

    # [0] Cosine similarity (embeddings are L2-normed, so dot product = cosine).
    cos_sim = (emb_a * emb_b).sum(dim=-1)

    # [1] Absolute degree difference.
    degree = torch.zeros(n, device=dev)
    if edge_index.numel() > 0:
        src = edge_index[0]
        ones = torch.ones(src.size(0), device=dev)
        degree = degree.scatter_add(0, src, ones)
    abs_deg_diff = (degree[a_idx] - degree[b_idx]).abs()
    # Normalise by max degree to keep scale reasonable.
    max_deg = degree.max().clamp(min=1.0)
    abs_deg_diff = abs_deg_diff / max_deg

    # [2] Type match flag: 1.0 if both devices have the same type one-hot.
    # Type is encoded in columns 0:6 of node_features.
    type_a = node_features[a_idx, :6].argmax(dim=-1)
    type_b = node_features[b_idx, :6].argmax(dim=-1)
    type_match = (type_a == type_b).float()

    # [3] Structural fingerprint L2 distance (columns 12:16).
    fp_a = node_features[a_idx, 12:16]
    fp_b = node_features[b_idx, 12:16]
    fp_l2 = (fp_a - fp_b).pow(2).sum(dim=-1).sqrt()

    # [4] Hadamard product projected to scalar.
    hadamard_scalar = (emb_a * emb_b).sum(dim=-1)

    # [5] L1 distance.
    l1_dist = (emb_a - emb_b).abs().sum(dim=-1)

    # [6] Embedding norm ratio: max(norm_a, norm_b) / (min(norm_a, norm_b) + eps).
    norm_a = emb_a.norm(dim=-1)
    norm_b = emb_b.norm(dim=-1)
    norm_max = torch.max(norm_a, norm_b)
    norm_min = torch.min(norm_a, norm_b)
    norm_ratio = norm_max / (norm_min + 1e-8)

    return torch.stack(
        [cos_sim, abs_deg_diff, type_match, fp_l2,
         hadamard_scalar, l1_dist, norm_ratio],
        dim=-1,
    )


def train_learned_threshold(
    model: nn.Module,
    val_graphs: list[dict[str, torch.Tensor]],
    device: torch.device,
    classifier_epochs: int = 50,
    classifier_lr: float = 0.01,
    verbose: bool = True,
) -> PairClassifier:
    """Train a PairClassifier on validation graph embeddings.

    Builds positive and negative pair samples from the validation graphs,
    extracts 4-dim pair features, and trains the MLP with BCE loss.

    Args:
        model: Trained GNN encoder (used in eval mode to produce embeddings).
        val_graphs: Validation graph dicts with x, edge_index, edge_attr,
            positive_pairs keys.
        device: Compute device.
        classifier_epochs: Number of training epochs for the classifier.
        classifier_lr: Learning rate for the classifier.
        verbose: Log progress.

    Returns:
        Trained PairClassifier on the specified device.
    """
    model.eval()
    all_features: list[torch.Tensor] = []
    all_labels: list[torch.Tensor] = []

    with torch.no_grad():
        for g in val_graphs:
            x = g["x"].to(device)
            ei = g["edge_index"].to(device)
            ea = g.get("edge_attr")
            if ea is not None:
                ea = ea.to(device)
            pp = g["positive_pairs"].to(device)

            if pp.numel() == 0:
                continue

            embeddings = model(x, ei, edge_attr=ea, project=False)
            n = embeddings.size(0)

            # Build positive pair set.
            pos_set: set[tuple[int, int]] = set()
            for pidx in range(pp.size(0)):
                a, b = int(pp[pidx, 0]), int(pp[pidx, 1])
                if a < n and b < n:
                    pos_set.add((min(a, b), max(a, b)))

            if not pos_set:
                continue

            # Sample negative pairs: ~3x the number of positives for balance.
            row, col = torch.triu_indices(n, n, offset=1, device=device)
            neg_candidates = []
            for pidx in range(row.size(0)):
                pair = (int(row[pidx]), int(col[pidx]))
                if pair not in pos_set:
                    neg_candidates.append(pair)

            n_neg = min(len(neg_candidates), 3 * len(pos_set))
            if n_neg > 0:
                rng = np.random.default_rng(42)
                neg_indices = rng.choice(len(neg_candidates), size=n_neg, replace=False)
                neg_pairs = [neg_candidates[i] for i in neg_indices]
            else:
                neg_pairs = []

            # Combine positive and negative pairs.
            all_pairs = list(pos_set) + neg_pairs
            labels = [1.0] * len(pos_set) + [0.0] * len(neg_pairs)

            pair_tensor = torch.tensor(all_pairs, dtype=torch.long, device=device)
            label_tensor = torch.tensor(labels, dtype=torch.float32, device=device)

            feats = _compute_pair_features(embeddings, x, ei, pair_tensor)
            all_features.append(feats)
            all_labels.append(label_tensor)

    if not all_features:
        logger.warning("No valid pairs found for learned threshold training.")
        classifier = PairClassifier().to(device)
        return classifier

    X = torch.cat(all_features, dim=0)
    Y = torch.cat(all_labels, dim=0)

    logger.info(
        "Training learned threshold classifier: %d samples (%d pos, %d neg)",
        X.size(0), int(Y.sum()), int((1 - Y).sum()),
    )

    classifier = PairClassifier().to(device)
    opt = torch.optim.Adam(classifier.parameters(), lr=classifier_lr)
    bce = nn.BCELoss()

    for ep in range(1, classifier_epochs + 1):
        classifier.train()
        opt.zero_grad()
        pred = classifier(X)
        loss = bce(pred, Y)
        loss.backward()
        opt.step()

        if verbose and (ep % 10 == 0 or ep == 1):
            with torch.no_grad():
                acc = ((pred > 0.5).float() == Y).float().mean()
            logger.info(
                "  Classifier epoch %3d/%d  loss=%.4f  acc=%.4f",
                ep, classifier_epochs, loss.item(), acc.item(),
            )

    # Final accuracy.
    classifier.eval()
    with torch.no_grad():
        pred = classifier(X)
        acc = ((pred > 0.5).float() == Y).float().mean()
        tp = ((pred > 0.5) & (Y == 1)).sum()
        fp = ((pred > 0.5) & (Y == 0)).sum()
        fn = ((pred <= 0.5) & (Y == 1)).sum()
        prec = tp / (tp + fp).clamp(min=1)
        rec = tp / (tp + fn).clamp(min=1)
        f1 = 2 * prec * rec / (prec + rec).clamp(min=1e-8)
        logger.info(
            "  Classifier final: acc=%.4f  prec=%.4f  rec=%.4f  F1=%.4f",
            acc.item(), prec.item(), rec.item(), f1.item(),
        )

    return classifier


def evaluate_with_learned_threshold(
    model: nn.Module,
    classifier: PairClassifier,
    graphs: list[dict[str, torch.Tensor]],
    device: torch.device,
) -> dict[str, float]:
    """Evaluate constraint prediction using the learned threshold classifier.

    Args:
        model: Trained GNN encoder.
        classifier: Trained PairClassifier.
        graphs: List of graph dicts to evaluate.
        device: Compute device.

    Returns:
        Dict with precision, recall, f1 (averaged over graphs).
    """
    model.eval()
    classifier.eval()
    all_f1: list[float] = []
    all_prec: list[float] = []
    all_rec: list[float] = []

    with torch.no_grad():
        for g in graphs:
            x = g["x"].to(device)
            ei = g["edge_index"].to(device)
            ea = g.get("edge_attr")
            if ea is not None:
                ea = ea.to(device)
            pp = g["positive_pairs"].to(device)

            if pp.numel() == 0:
                continue

            embeddings = model(x, ei, edge_attr=ea, project=False)
            n = embeddings.size(0)

            # Ground truth set.
            gt_set: set[tuple[int, int]] = set()
            for pidx in range(pp.size(0)):
                a, b = int(pp[pidx, 0]), int(pp[pidx, 1])
                if a < n and b < n:
                    gt_set.add((min(a, b), max(a, b)))

            if not gt_set:
                continue

            # All candidate pairs.
            row, col = torch.triu_indices(n, n, offset=1, device=device)
            pair_tensor = torch.stack([row, col], dim=1)
            feats = _compute_pair_features(embeddings, x, ei, pair_tensor)
            preds = classifier(feats)

            # Predicted set.
            pred_mask = preds > 0.5
            pred_set: set[tuple[int, int]] = set()
            pred_indices = torch.where(pred_mask)[0]
            for pi in pred_indices:
                pred_set.add((int(row[pi]), int(col[pi])))

            tp = len(gt_set & pred_set)
            fp = len(pred_set - gt_set)
            fn = len(gt_set - pred_set)

            precision = tp / max(tp + fp, 1)
            recall = tp / max(tp + fn, 1)
            f1 = 2 * precision * recall / max(precision + recall, 1e-12)

            all_f1.append(f1)
            all_prec.append(precision)
            all_rec.append(recall)

    if not all_f1:
        return {"precision": 0.0, "recall": 0.0, "f1": 0.0}

    return {
        "precision": float(np.mean(all_prec)),
        "recall": float(np.mean(all_rec)),
        "f1": float(np.mean(all_f1)),
    }


# ---------------------------------------------------------------------------
# Synthetic data generation -- topology-aware device-only circuit graphs
# ---------------------------------------------------------------------------

# Terminal type indices (matching edge_attr encoding).
TERM_GATE = 0
TERM_DRAIN = 1
TERM_SOURCE = 2
TERM_BODY = 3


def _build_device_graph_from_pins(
    n_devices: int,
    pins: list[tuple[int, int, int]],
) -> tuple[np.ndarray, np.ndarray]:
    """Convert pin-level connectivity into a device-device graph with edge features.

    Args:
        n_devices: Number of device nodes.
        pins: List of (device_id, net_id, terminal_type) tuples.

    Returns:
        (edge_index, edge_attr):
            edge_index: int64 (2, E) COO format, bidirectional.
            edge_attr: float32 (E, 5) -- [gate_shared, drain_shared, source_shared,
                       body_shared, n_shared_nets_normalized].
    """
    # Group pins by net.
    net_to_pins: dict[int, list[tuple[int, int]]] = defaultdict(list)
    for dev, net, term in pins:
        net_to_pins[net].append((dev, term))

    # For each pair of devices sharing a net, accumulate terminal info.
    # Key: (min_dev, max_dev), Value: set of shared net IDs + terminal types.
    pair_info: dict[tuple[int, int], dict] = {}

    for net_id, dev_pins in net_to_pins.items():
        # Get unique devices on this net.
        devs_on_net = list(set(dp[0] for dp in dev_pins))
        if len(devs_on_net) < 2:
            continue

        # Terminal types present per device on this net.
        dev_terms: dict[int, set[int]] = defaultdict(set)
        for dev, term in dev_pins:
            dev_terms[dev].add(term)

        for i in range(len(devs_on_net)):
            for j in range(i + 1, len(devs_on_net)):
                d_a, d_b = devs_on_net[i], devs_on_net[j]
                key = (min(d_a, d_b), max(d_a, d_b))
                if key not in pair_info:
                    pair_info[key] = {
                        "shared_nets": 0,
                        "term_flags": [0.0, 0.0, 0.0, 0.0],
                    }
                pair_info[key]["shared_nets"] += 1

                # Mark which terminal types connect through this shared net.
                for t in dev_terms[d_a] & dev_terms[d_b]:
                    pair_info[key]["term_flags"][t] = 1.0

    # Build edge_index and edge_attr.
    src_list: list[int] = []
    dst_list: list[int] = []
    attr_list: list[list[float]] = []

    max_shared = max((info["shared_nets"] for info in pair_info.values()), default=1)

    for (d_a, d_b), info in pair_info.items():
        attr = info["term_flags"][:] + [info["shared_nets"] / max(max_shared, 1)]

        # Bidirectional.
        src_list.append(d_a)
        dst_list.append(d_b)
        attr_list.append(attr)
        src_list.append(d_b)
        dst_list.append(d_a)
        attr_list.append(attr)

    if not src_list:
        return np.zeros((2, 0), dtype=np.int64), np.zeros((0, 5), dtype=np.float32)

    edge_index = np.array([src_list, dst_list], dtype=np.int64)
    edge_attr = np.array(attr_list, dtype=np.float32)
    return edge_index, edge_attr


def generate_synthetic_constraint_data(
    n_nodes: int = 50,
    n_edges: int = 150,
    n_positive_pairs: int = 10,
    seed: int | None = None,
) -> dict[str, torch.Tensor]:
    """Generate a single synthetic circuit graph with topology-aware constraint labels.

    Creates a device-only graph where edges connect devices sharing nets.
    Positive pairs (constrained devices) are identifiable from graph topology:
      - Differential pairs: two devices sharing a source net, different gate nets.
      - Current mirrors: two devices sharing a gate net, one diode-connected.
      - Common-centroid groups: matched devices with shared source and body nets.

    Edge features are 5-dim: [gate_shared, drain_shared, source_shared,
    body_shared, n_shared_nets_normalized].

    Matched device features have noise (std=0.15) so the GNN must rely on
    topology, not just feature similarity.

    Args:
        n_nodes: Number of device nodes in the graph.
        n_edges: Ignored (kept for API compat); edges derived from topology.
        n_positive_pairs: Target number of constraint pairs to generate.
        seed: Optional random seed.

    Returns:
        Dict with keys x, edge_index, edge_attr, and positive_pairs.
    """
    rng = np.random.default_rng(seed)

    n_devices = max(n_nodes, 12)

    # --- Device features: type one-hot(6) + W, L, fingers, mult, x, y ---
    type_idx = rng.integers(0, 6, size=n_devices)
    type_onehot = np.zeros((n_devices, 6), dtype=np.float32)
    type_onehot[np.arange(n_devices), type_idx] = 1.0

    W = rng.uniform(0.2, 5.0, size=n_devices).astype(np.float32)
    L = rng.uniform(0.1, 2.0, size=n_devices).astype(np.float32)
    fingers = rng.integers(1, 8, size=n_devices).astype(np.float32)
    mult = rng.integers(1, 4, size=n_devices).astype(np.float32)
    pos_x = rng.uniform(-50, 50, size=n_devices).astype(np.float32)
    pos_y = rng.uniform(-50, 50, size=n_devices).astype(np.float32)

    # --- Build pin-level connectivity with constraint patterns ---
    net_counter = 0
    pins: list[tuple[int, int, int]] = []  # (device, net, terminal)
    positive_pairs: list[tuple[int, int]] = []

    n_pos = min(n_positive_pairs, n_devices // 3)
    used_devices: set[int] = set()

    def pick_pair() -> tuple[int, int] | None:
        available = [d for d in range(n_devices) if d not in used_devices]
        if len(available) < 2:
            return None
        chosen = rng.choice(available, size=2, replace=False)
        used_devices.add(int(chosen[0]))
        used_devices.add(int(chosen[1]))
        return int(chosen[0]), int(chosen[1])

    def match_features(d_a: int, d_b: int) -> None:
        """Make two devices have similar features with noise."""
        type_idx[d_b] = type_idx[d_a]
        type_onehot[d_b] = type_onehot[d_a]
        W[d_b] = W[d_a] * (1.0 + rng.normal(0, 0.15))
        L[d_b] = L[d_a] * (1.0 + rng.normal(0, 0.15))
        fingers[d_b] = fingers[d_a]
        mult[d_b] = mult[d_a]

    # Pattern 1: Differential pairs (~40%)
    n_diff = max(1, int(n_pos * 0.4))
    for _ in range(n_diff):
        pair = pick_pair()
        if pair is None:
            break
        d_a, d_b = pair
        match_features(d_a, d_b)

        # Shared source net, different gate/drain nets.
        shared_source = net_counter; net_counter += 1
        gate_a = net_counter; net_counter += 1
        gate_b = net_counter; net_counter += 1
        drain_a = net_counter; net_counter += 1
        drain_b = net_counter; net_counter += 1
        body_net = net_counter; net_counter += 1

        pins.append((d_a, gate_a, TERM_GATE))
        pins.append((d_b, gate_b, TERM_GATE))
        pins.append((d_a, drain_a, TERM_DRAIN))
        pins.append((d_b, drain_b, TERM_DRAIN))
        pins.append((d_a, shared_source, TERM_SOURCE))
        pins.append((d_b, shared_source, TERM_SOURCE))
        pins.append((d_a, body_net, TERM_BODY))
        pins.append((d_b, body_net, TERM_BODY))

        positive_pairs.append((min(d_a, d_b), max(d_a, d_b)))

    # Pattern 2: Current mirrors (~30%)
    n_mirror = max(1, int(n_pos * 0.3))
    for _ in range(n_mirror):
        pair = pick_pair()
        if pair is None:
            break
        d_a, d_b = pair
        match_features(d_a, d_b)

        # Shared gate net; d_a is diode-connected (gate=drain).
        shared_gate = net_counter; net_counter += 1
        drain_b_net = net_counter; net_counter += 1
        source_a = net_counter; net_counter += 1
        source_b = net_counter; net_counter += 1
        body_net = net_counter; net_counter += 1

        pins.append((d_a, shared_gate, TERM_GATE))
        pins.append((d_b, shared_gate, TERM_GATE))
        pins.append((d_a, shared_gate, TERM_DRAIN))  # diode: gate == drain
        pins.append((d_b, drain_b_net, TERM_DRAIN))
        pins.append((d_a, source_a, TERM_SOURCE))
        pins.append((d_b, source_b, TERM_SOURCE))
        pins.append((d_a, body_net, TERM_BODY))
        pins.append((d_b, body_net, TERM_BODY))

        positive_pairs.append((min(d_a, d_b), max(d_a, d_b)))

    # Pattern 3: Common-centroid groups (~30%)
    n_cc = max(1, int(n_pos * 0.3))
    for _ in range(n_cc):
        pair = pick_pair()
        if pair is None:
            break
        d_a, d_b = pair
        match_features(d_a, d_b)

        # Mirror positions.
        pos_x[d_b] = -pos_x[d_a] + rng.normal(0, 2.0)
        pos_y[d_b] = -pos_y[d_a] + rng.normal(0, 2.0)

        # Different gate/drain, shared source and body.
        gate_a = net_counter; net_counter += 1
        gate_b = net_counter; net_counter += 1
        drain_a = net_counter; net_counter += 1
        drain_b = net_counter; net_counter += 1
        shared_source = net_counter; net_counter += 1
        shared_body = net_counter; net_counter += 1

        pins.append((d_a, gate_a, TERM_GATE))
        pins.append((d_b, gate_b, TERM_GATE))
        pins.append((d_a, drain_a, TERM_DRAIN))
        pins.append((d_b, drain_b, TERM_DRAIN))
        pins.append((d_a, shared_source, TERM_SOURCE))
        pins.append((d_b, shared_source, TERM_SOURCE))
        pins.append((d_a, shared_body, TERM_BODY))
        pins.append((d_b, shared_body, TERM_BODY))

        positive_pairs.append((min(d_a, d_b), max(d_a, d_b)))

    # --- Connect remaining unconstrained devices to unique nets ---
    # Each gets its own set of nets (no sharing with other devices).
    for d in range(n_devices):
        if d in used_devices:
            continue
        for term in [TERM_GATE, TERM_DRAIN, TERM_SOURCE, TERM_BODY]:
            net = net_counter; net_counter += 1
            pins.append((d, net, term))

    # --- Compute structural fingerprint from CLEAN topology (before noise) ---
    struct_fp = compute_structural_fingerprint(n_devices, pins)

    # Add some random cross-connections to create noise edges.
    # Only connect UNCONSTRAINED devices to avoid corrupting constraint topology.
    unconstrained = [d for d in range(n_devices) if d not in used_devices]
    n_random_nets = max(5, n_devices // 4)
    random_nets = list(range(net_counter, net_counter + n_random_nets))
    net_counter += n_random_nets

    for rnet in random_nets:
        # Connect 2-4 unconstrained devices to this net.
        n_conn = rng.integers(2, 5)
        if len(unconstrained) >= n_conn:
            devs = rng.choice(unconstrained, size=n_conn, replace=False)
        else:
            devs = rng.choice(unconstrained, size=min(n_conn, len(unconstrained)), replace=False)
        for d in devs:
            term = rng.integers(0, 4)
            pins.append((int(d), rnet, int(term)))

    # --- Bias net cross-connections (hard negatives) ---
    # Connect 3-5 unconstrained same-type devices to shared gate bias nets.
    if len(unconstrained) >= 3:
        type_groups: dict[int, list[int]] = defaultdict(list)
        for d in unconstrained:
            type_groups[int(type_idx[d])].append(d)

        for _typ, devs_of_type in type_groups.items():
            if len(devs_of_type) < 3:
                continue
            n_bias = min(rng.integers(3, 6), len(devs_of_type))
            bias_devs = rng.choice(devs_of_type, size=n_bias, replace=False)
            bias_gate_net = net_counter; net_counter += 1
            for d in bias_devs:
                pins.append((int(d), bias_gate_net, TERM_GATE))

    # --- Build feature matrix ---

    x = np.concatenate([
        type_onehot,
        W[:, None], L[:, None], fingers[:, None], mult[:, None],
        pos_x[:, None], pos_y[:, None],
        struct_fp,
    ], axis=1).astype(np.float32)

    # --- Build device-device graph from pins ---
    edge_index, edge_attr = _build_device_graph_from_pins(n_devices, pins)

    if not positive_pairs:
        pp = np.zeros((0, 2), dtype=np.int64)
    else:
        pp = np.array(positive_pairs, dtype=np.int64)

    return {
        "x": torch.from_numpy(x),
        "edge_index": torch.from_numpy(edge_index),
        "edge_attr": torch.from_numpy(edge_attr),
        "positive_pairs": torch.from_numpy(pp),
        "n_devices": n_devices,
    }


def generate_synthetic_dataset(
    n_graphs: int = 200,
    seed: int = 42,
) -> list[dict[str, torch.Tensor]]:
    """Generate a list of synthetic constraint graphs.

    Args:
        n_graphs: Number of graphs to generate.
        seed: Base random seed; each graph uses seed+i.

    Returns:
        List of dicts, each with x, edge_index, edge_attr, and positive_pairs.
    """
    rng = np.random.default_rng(seed)
    graphs = []
    for i in range(n_graphs):
        n_nodes = int(rng.integers(20, 60))
        n_pos = int(rng.integers(3, max(4, n_nodes // 5)))
        graphs.append(
            generate_synthetic_constraint_data(
                n_nodes=n_nodes,
                n_positive_pairs=n_pos,
                seed=seed + i,
            )
        )
    return graphs


def generate_synthetic_data(
    n_samples: int = 200,
    seed: int = 42,
) -> list[dict[str, torch.Tensor]]:
    """Alias for generate_synthetic_dataset (called by auto_train.py).

    Args:
        n_samples: Number of graphs.
        seed: Base random seed.

    Returns:
        List of graph dicts.
    """
    return generate_synthetic_dataset(n_graphs=n_samples, seed=seed)


# ---------------------------------------------------------------------------
# Dataset cache -- avoid re-generating synthetic graphs every run
# ---------------------------------------------------------------------------

# Default cache path relative to project root.
_CACHE_DIR = "fixtures/benchmark/cache"
_CACHE_FILENAME = "constraint_synth.pt"


def _find_project_root() -> pathlib.Path:
    """Walk up from this file to find the project root (contains build.zig)."""
    current = pathlib.Path(__file__).resolve().parent
    for _ in range(10):
        if (current / "build.zig").exists():
            return current
        parent = current.parent
        if parent == current:
            break
        current = parent
    # Fallback: two levels up from python/constraint/
    return pathlib.Path(__file__).resolve().parent.parent.parent


def load_or_generate_dataset(
    n_graphs: int = 200,
    seed: int = 42,
    use_cache: bool = True,
) -> list[dict[str, torch.Tensor]]:
    """Load synthetic dataset from cache, or generate and save it.

    Checks ``fixtures/benchmark/cache/constraint_synth.pt``. If found, loads and
    returns the cached graphs. Otherwise generates a new dataset with
    :func:`generate_synthetic_dataset`, saves it to the cache path, and
    returns it.

    Args:
        n_graphs: Number of graphs to generate (only used on cache miss).
        seed: Base random seed (only used on cache miss).
        use_cache: If False, always regenerate (skip cache).

    Returns:
        List of graph dicts.
    """
    root = _find_project_root()
    cache_path = root / _CACHE_DIR / _CACHE_FILENAME

    if use_cache and cache_path.exists():
        logger.info("Loading cached constraint dataset from %s", cache_path)
        try:
            graphs = torch.load(cache_path, map_location="cpu", weights_only=False)
            if isinstance(graphs, list) and len(graphs) > 0:
                logger.info("Loaded %d cached graphs.", len(graphs))
                return graphs
        except Exception as exc:
            logger.warning("Cache load failed (%s), regenerating...", exc)

    logger.info("Generating %d synthetic constraint graphs...", n_graphs)
    graphs = generate_synthetic_dataset(n_graphs=n_graphs, seed=seed)
    logger.info("Generated %d graphs.", len(graphs))

    if use_cache:
        try:
            cache_path.parent.mkdir(parents=True, exist_ok=True)
            torch.save(graphs, cache_path)
            logger.info("Saved dataset cache to %s", cache_path)
        except Exception as exc:
            logger.warning("Failed to save cache (%s), continuing.", exc)

    return graphs


# ---------------------------------------------------------------------------
# Real SPICE netlist parsing
# ---------------------------------------------------------------------------


def _parse_spice_value(s: str) -> float:
    """Parse a SPICE numeric value with SI suffixes (e.g. '1u', '270e-9', '0.15u').

    Handles common suffixes: f, p, n, u, m, k, meg, g, t.
    Returns the value as a float, or 0.0 on failure.
    """
    s = s.strip().lower()
    suffixes = {
        "t": 1e12, "g": 1e9, "meg": 1e6, "k": 1e3,
        "m": 1e-3, "u": 1e-6, "n": 1e-9, "p": 1e-12, "f": 1e-15,
    }
    # Try longest suffix first (meg before m).
    for suffix, mult in sorted(suffixes.items(), key=lambda x: -len(x[0])):
        if s.endswith(suffix):
            try:
                return float(s[: -len(suffix)]) * mult
            except ValueError:
                return 0.0
    try:
        return float(s)
    except ValueError:
        return 0.0


def _parse_spice_netlist(filepath: str | pathlib.Path) -> list[dict[str, Any]]:
    """Parse a SPICE netlist file and extract MOSFET device information.

    Handles standard SPICE MOSFET instance lines of the form:
        Mname drain gate source body model_name [param=value ...]

    Also handles resistors (Rname n1 n2 value) and capacitors (Cname n1 n2 value).

    Args:
        filepath: Path to the .spice/.cir/.sp file.

    Returns:
        List of device dicts with keys: name, type, nets (list of net names),
        params (dict of W, L, M, NF, etc.).
    """
    devices: list[dict[str, Any]] = []
    filepath = pathlib.Path(filepath)

    try:
        lines = filepath.read_text().splitlines()
    except Exception:
        return devices

    for raw_line in lines:
        line = raw_line.strip()
        # Skip comments, directives, empty lines.
        if not line or line.startswith("*") or line.startswith("."):
            continue

        tokens = line.split()
        if len(tokens) < 2:
            continue

        name = tokens[0]
        first_char = name[0].upper()

        if first_char == "M" and len(tokens) >= 5:
            # MOSFET: Mname drain gate source body [model] [params...]
            drain, gate, source, body = tokens[1], tokens[2], tokens[3], tokens[4]
            # Determine model name -- token after body if it doesn't contain '='.
            model = ""
            param_start = 5
            if len(tokens) > 5 and "=" not in tokens[5]:
                model = tokens[5].lower()
                param_start = 6

            # Parse key=value parameters.
            params: dict[str, float] = {}
            for tok in tokens[param_start:]:
                if "=" in tok:
                    k, v = tok.split("=", 1)
                    params[k.lower()] = _parse_spice_value(v)

            # Determine NMOS vs PMOS from model name.
            dev_type = "nmos"
            if "pmos" in model or "pfet" in model:
                dev_type = "pmos"

            devices.append({
                "name": name,
                "type": dev_type,
                "nets": [drain, gate, source, body],
                "params": params,
            })

        elif first_char == "R" and len(tokens) >= 3:
            # Resistor: Rname n1 n2 [value] [params...]
            params = {}
            for tok in tokens[3:]:
                if "=" in tok:
                    k, v = tok.split("=", 1)
                    params[k.lower()] = _parse_spice_value(v)
            if len(tokens) > 3 and "=" not in tokens[3]:
                params["r"] = _parse_spice_value(tokens[3])
            devices.append({
                "name": name,
                "type": "r",
                "nets": [tokens[1], tokens[2]],
                "params": params,
            })

        elif first_char == "C" and len(tokens) >= 3:
            # Capacitor: Cname n1 n2 [value] [params...]
            params = {}
            for tok in tokens[3:]:
                if "=" in tok:
                    k, v = tok.split("=", 1)
                    params[k.lower()] = _parse_spice_value(v)
            if len(tokens) > 3 and "=" not in tokens[3]:
                params["c"] = _parse_spice_value(tokens[3])
            devices.append({
                "name": name,
                "type": "c",
                "nets": [tokens[1], tokens[2]],
                "params": params,
            })

    return devices


def _devices_to_constraint_graph(
    devices: list[dict[str, Any]],
) -> dict[str, torch.Tensor] | None:
    """Convert parsed SPICE devices into a constraint graph in the same format
    as generate_synthetic_constraint_data().

    Node features: type one-hot (6) + W, L, fingers, mult, x, y (6)
                   + structural fingerprint (4) = 16 dims.
    Edge features: 5-dim from _build_device_graph_from_pins.

    Constraint labels are heuristic: devices with matching type, W, and L
    that share a gate or source net are candidate constraint pairs.

    Args:
        devices: List of device dicts from _parse_spice_netlist.

    Returns:
        Graph dict with x, edge_index, edge_attr, positive_pairs, n_devices.
        None if the netlist has fewer than 2 devices.
    """
    if len(devices) < 2:
        return None

    n_devices = len(devices)

    # Type encoding: {nmos: 0, pmos: 1, r: 2, c: 3, other: 4, 5 reserved}.
    TYPE_MAP = {"nmos": 0, "pmos": 1, "r": 2, "c": 3}

    type_idx = np.zeros(n_devices, dtype=np.int64)
    type_onehot = np.zeros((n_devices, 6), dtype=np.float32)
    W = np.zeros(n_devices, dtype=np.float32)
    L = np.zeros(n_devices, dtype=np.float32)
    fingers = np.ones(n_devices, dtype=np.float32)
    mult = np.ones(n_devices, dtype=np.float32)
    pos_x = np.zeros(n_devices, dtype=np.float32)
    pos_y = np.zeros(n_devices, dtype=np.float32)

    # Assign unique integer IDs to net names.
    net_name_to_id: dict[str, int] = {}
    net_counter = 0

    def get_net_id(name: str) -> int:
        nonlocal net_counter
        key = name.lower()
        if key not in net_name_to_id:
            net_name_to_id[key] = net_counter
            net_counter += 1
        return net_name_to_id[key]

    pins: list[tuple[int, int, int]] = []

    for dev_idx, dev in enumerate(devices):
        tidx = TYPE_MAP.get(dev["type"], 4)
        type_idx[dev_idx] = tidx
        type_onehot[dev_idx, tidx] = 1.0

        p = dev["params"]
        # Normalise W and L to microns for consistent scale.
        w_val = p.get("w", 0.0)
        l_val = p.get("l", 0.0)
        # If values are very small (< 1e-3), assume meters -> convert to microns.
        if 0 < w_val < 1e-3:
            w_val *= 1e6
        if 0 < l_val < 1e-3:
            l_val *= 1e6
        W[dev_idx] = w_val
        L[dev_idx] = l_val
        fingers[dev_idx] = p.get("nf", p.get("nfin", p.get("fingers", 1.0)))
        mult[dev_idx] = p.get("m", p.get("mult", 1.0))

        nets = dev["nets"]
        if dev["type"] in ("nmos", "pmos") and len(nets) >= 4:
            # MOSFET: drain, gate, source, body
            drain_net = get_net_id(nets[0])
            gate_net = get_net_id(nets[1])
            source_net = get_net_id(nets[2])
            body_net = get_net_id(nets[3])
            pins.append((dev_idx, gate_net, TERM_GATE))
            pins.append((dev_idx, drain_net, TERM_DRAIN))
            pins.append((dev_idx, source_net, TERM_SOURCE))
            pins.append((dev_idx, body_net, TERM_BODY))
        elif len(nets) >= 2:
            # Two-terminal device (R, C): connect as gate+drain on the two nets.
            net_a = get_net_id(nets[0])
            net_b = get_net_id(nets[1])
            pins.append((dev_idx, net_a, TERM_GATE))
            pins.append((dev_idx, net_b, TERM_DRAIN))

    # Compute structural fingerprint.
    struct_fp = compute_structural_fingerprint(n_devices, pins)

    # Build feature matrix (same 16-dim format as synthetic data).
    x = np.concatenate([
        type_onehot,
        W[:, None], L[:, None], fingers[:, None], mult[:, None],
        pos_x[:, None], pos_y[:, None],
        struct_fp,
    ], axis=1).astype(np.float32)

    # Build device-device graph from pins.
    edge_index, edge_attr = _build_device_graph_from_pins(n_devices, pins)

    # --- Heuristic constraint labels ---
    # Devices with matching type + W + L that share a gate or source net
    # are candidate constraint pairs (differential pairs, current mirrors).
    positive_pairs: list[tuple[int, int]] = []
    W_TOL = 0.01  # Relative tolerance for W/L matching.
    L_TOL = 0.01

    # Group by net to find devices sharing gate or source nets.
    net_to_devs: dict[int, list[int]] = defaultdict(list)
    for dev_idx_p, net_id, term_type in pins:
        if term_type in (TERM_GATE, TERM_SOURCE):
            net_to_devs[net_id].append(dev_idx_p)

    seen_pairs: set[tuple[int, int]] = set()
    for _net_id, dev_list in net_to_devs.items():
        unique_devs = list(set(dev_list))
        if len(unique_devs) < 2:
            continue
        for i in range(len(unique_devs)):
            for j in range(i + 1, len(unique_devs)):
                da, db = unique_devs[i], unique_devs[j]
                key = (min(da, db), max(da, db))
                if key in seen_pairs:
                    continue

                # Must be same type.
                if type_idx[da] != type_idx[db]:
                    continue
                # Must have matching W and L (within tolerance).
                if W[da] == 0 or W[db] == 0:
                    continue
                w_ratio = abs(W[da] - W[db]) / max(W[da], W[db])
                l_ratio = abs(L[da] - L[db]) / max(L[da], L[db], 1e-12)
                if w_ratio > W_TOL or l_ratio > L_TOL:
                    continue

                seen_pairs.add(key)
                positive_pairs.append(key)

    if not positive_pairs:
        pp = np.zeros((0, 2), dtype=np.int64)
    else:
        pp = np.array(positive_pairs, dtype=np.int64)

    return {
        "x": torch.from_numpy(x),
        "edge_index": torch.from_numpy(edge_index),
        "edge_attr": torch.from_numpy(edge_attr),
        "positive_pairs": torch.from_numpy(pp),
        "n_devices": n_devices,
    }


def load_real_circuit_data(
    data_dir: str | pathlib.Path,
) -> list[dict[str, torch.Tensor]]:
    """Load real SPICE netlists from a directory and convert to constraint graphs.

    Finds all .spice, .cir, and .sp files in the given directory (non-recursive),
    parses each, and builds graph dicts in the same format as
    generate_synthetic_constraint_data().

    Skips LVS/PEX variants (filenames containing '_lvs' or '_pex') to avoid
    duplicates -- these are post-layout netlists of the same circuits.

    Args:
        data_dir: Path to directory containing SPICE netlist files.

    Returns:
        List of graph dicts (only those with >= 2 devices and at least 1 edge).
    """
    data_dir = pathlib.Path(data_dir)
    if not data_dir.is_dir():
        logger.warning("Data directory does not exist: %s", data_dir)
        return []

    graphs: list[dict[str, torch.Tensor]] = []
    spice_files = sorted(
        f for f in data_dir.iterdir()
        if f.suffix in (".spice", ".cir", ".sp")
        and "_lvs" not in f.stem
        and "_pex" not in f.stem
    )

    logger.info("Found %d SPICE files in %s", len(spice_files), data_dir)

    for fpath in spice_files:
        devices = _parse_spice_netlist(fpath)
        if len(devices) < 2:
            logger.debug("Skipping %s: fewer than 2 devices", fpath.name)
            continue

        graph = _devices_to_constraint_graph(devices)
        if graph is None:
            continue

        # Skip graphs with no edges (disconnected devices).
        if graph["edge_index"].numel() == 0:
            logger.debug("Skipping %s: no edges", fpath.name)
            continue

        logger.info(
            "  %s: %d devices, %d edges, %d constraint pairs",
            fpath.name,
            graph["n_devices"],
            graph["edge_index"].size(1) // 2,
            graph["positive_pairs"].size(0),
        )
        graphs.append(graph)

    logger.info("Loaded %d real circuit graphs.", len(graphs))
    return graphs


# ---------------------------------------------------------------------------
# Metrics
# ---------------------------------------------------------------------------


def compute_f1(
    embeddings: torch.Tensor,
    positive_pairs: torch.Tensor,
    threshold: float | None = None,
    n_devices: int | None = None,
) -> dict[str, float]:
    """Compute precision, recall, F1, and AUC for constraint prediction.

    If threshold is None, sweeps multiple thresholds and returns the best F1.
    Only considers device-device pairs (indices < n_devices) if n_devices is given.

    Args:
        embeddings: (N, D) L2-normalised device embeddings.
        positive_pairs: (P, 2) ground-truth symmetry/matching pair indices.
        threshold: Cosine similarity threshold. If None, finds optimal.
        n_devices: If provided, only score pairs among device nodes [0, n_devices).

    Returns:
        Dict with precision, recall, f1, best_threshold, auc.
    """
    if positive_pairs.numel() == 0:
        return {"precision": 0.0, "recall": 0.0, "f1": 0.0,
                "best_threshold": 0.5, "auc": 0.0}

    # Only consider device nodes for similarity.
    if n_devices is not None and n_devices < embeddings.size(0):
        dev_emb = embeddings[:n_devices]
    else:
        dev_emb = embeddings
        n_devices = embeddings.size(0)

    n = dev_emb.size(0)
    sim = torch.mm(dev_emb, dev_emb.t())

    # All upper-triangular pairs among device nodes.
    row, col = torch.triu_indices(n, n, offset=1, device=dev_emb.device)
    scores = sim[row, col]

    # Build ground-truth set.
    gt_set: set[tuple[int, int]] = set()
    for idx in range(positive_pairs.size(0)):
        a, b = int(positive_pairs[idx, 0]), int(positive_pairs[idx, 1])
        if a < n and b < n:
            gt_set.add((min(a, b), max(a, b)))

    if not gt_set:
        return {"precision": 0.0, "recall": 0.0, "f1": 0.0,
                "best_threshold": 0.5, "auc": 0.0}

    # Build pair index for fast lookup.
    row_np = row.cpu().numpy()
    col_np = col.cpu().numpy()
    scores_np = scores.cpu().numpy()

    gt_labels = np.zeros(len(scores_np), dtype=bool)
    for idx_p in range(len(row_np)):
        pair = (int(row_np[idx_p]), int(col_np[idx_p]))
        if pair in gt_set:
            gt_labels[idx_p] = True

    # AUC: simple trapezoidal approximation.
    sorted_idx = np.argsort(-scores_np)
    sorted_labels = gt_labels[sorted_idx]
    n_pos_total = sorted_labels.sum()
    n_neg_total = len(sorted_labels) - n_pos_total
    auc = 0.0
    if n_pos_total > 0 and n_neg_total > 0:
        tp_cumsum = np.cumsum(sorted_labels).astype(np.float64)
        fp_cumsum = np.cumsum(~sorted_labels).astype(np.float64)
        tpr = tp_cumsum / n_pos_total
        fpr = fp_cumsum / n_neg_total
        # Prepend (0, 0).
        tpr = np.concatenate([[0.0], tpr])
        fpr = np.concatenate([[0.0], fpr])
        # np.trapz removed in NumPy 2.0; use np.trapezoid or fallback.
        _trapz = getattr(np, "trapezoid", getattr(np, "trapz", None))
        auc = float(_trapz(tpr, fpr))

    if threshold is not None:
        thresholds = [threshold]
    else:
        # Sweep thresholds from 0.01 to 0.999 with finer steps at extremes.
        thresholds = [t / 1000.0 for t in range(10, 100, 10)]
        thresholds += [t / 1000.0 for t in range(100, 950, 25)]
        thresholds += [t / 1000.0 for t in range(950, 1000, 2)]

    best_f1 = 0.0
    best_prec = 0.0
    best_rec = 0.0
    best_thr = 0.5

    for thr in thresholds:
        pred_mask = scores_np >= thr
        pred_set: set[tuple[int, int]] = set()
        pred_indices = np.where(pred_mask)[0]
        for pi in pred_indices:
            pred_set.add((int(row_np[pi]), int(col_np[pi])))

        tp = len(gt_set & pred_set)
        fp = len(pred_set - gt_set)
        fn = len(gt_set - pred_set)

        precision = tp / max(tp + fp, 1)
        recall = tp / max(tp + fn, 1)
        f1 = 2 * precision * recall / max(precision + recall, 1e-12)

        if f1 > best_f1:
            best_f1 = f1
            best_prec = precision
            best_rec = recall
            best_thr = thr

    return {
        "precision": best_prec,
        "recall": best_rec,
        "f1": best_f1,
        "best_threshold": best_thr,
        "auc": auc,
    }


def compute_f1_bce(
    model: nn.Module,
    x: torch.Tensor,
    edge_index: torch.Tensor,
    positive_pairs: torch.Tensor,
    edge_attr: torch.Tensor | None = None,
    threshold: float = 0.5,
) -> dict[str, float]:
    """Compute F1 using EdgeDecoder probabilities instead of cosine threshold.

    Args:
        model: ConstraintGraphSAGE with trained EdgeDecoder.
        x: (N, in_features) node features.
        edge_index: (2, E) COO edges.
        positive_pairs: (P, 2) ground-truth constraint pairs.
        edge_attr: optional edge features.
        threshold: probability threshold for prediction.

    Returns:
        Dict with precision, recall, f1, best_threshold, auc.
    """
    if positive_pairs.numel() == 0:
        return {"precision": 0.0, "recall": 0.0, "f1": 0.0,
                "best_threshold": 0.5, "auc": 0.0}

    dev = x.device
    raw_model = getattr(model, "_orig_mod", model)

    with torch.no_grad():
        embeddings = model(x, edge_index, edge_attr=edge_attr, normalize=False)
        n = embeddings.size(0)
        row, col = torch.triu_indices(n, n, offset=1, device=dev)
        z_u = embeddings[row]
        z_v = embeddings[col]
        probs = raw_model.edge_decoder.predict_proba(z_u, z_v)

    probs_np = probs.cpu().numpy()
    row_np = row.cpu().numpy()
    col_np = col.cpu().numpy()

    # Ground-truth set.
    gt_set: set[tuple[int, int]] = set()
    for idx in range(positive_pairs.size(0)):
        a, b = int(positive_pairs[idx, 0]), int(positive_pairs[idx, 1])
        if a < n and b < n:
            gt_set.add((min(a, b), max(a, b)))

    if not gt_set:
        return {"precision": 0.0, "recall": 0.0, "f1": 0.0,
                "best_threshold": 0.5, "auc": 0.0}

    # AUC.
    gt_labels = np.zeros(len(probs_np), dtype=bool)
    for idx_p in range(len(row_np)):
        pair = (int(row_np[idx_p]), int(col_np[idx_p]))
        if pair in gt_set:
            gt_labels[idx_p] = True

    sorted_idx = np.argsort(-probs_np)
    sorted_labels = gt_labels[sorted_idx]
    n_pos_total = sorted_labels.sum()
    n_neg_total = len(sorted_labels) - n_pos_total
    auc = 0.0
    if n_pos_total > 0 and n_neg_total > 0:
        tp_cumsum = np.cumsum(sorted_labels).astype(np.float64)
        fp_cumsum = np.cumsum(~sorted_labels).astype(np.float64)
        tpr = tp_cumsum / n_pos_total
        fpr = fp_cumsum / n_neg_total
        tpr = np.concatenate([[0.0], tpr])
        fpr = np.concatenate([[0.0], fpr])
        _trapz = getattr(np, "trapezoid", getattr(np, "trapz", None))
        auc = float(_trapz(tpr, fpr))

    # Sweep thresholds.
    thresholds = [t / 100.0 for t in range(5, 96, 5)]
    best_f1 = 0.0
    best_prec = 0.0
    best_rec = 0.0
    best_thr = 0.5

    for thr in thresholds:
        pred_mask = probs_np >= thr
        pred_indices = np.where(pred_mask)[0]
        pred_set: set[tuple[int, int]] = set()
        for pi in pred_indices:
            pred_set.add((int(row_np[pi]), int(col_np[pi])))

        tp = len(gt_set & pred_set)
        fp = len(pred_set - gt_set)
        fn = len(gt_set - pred_set)

        precision = tp / max(tp + fp, 1)
        recall = tp / max(tp + fn, 1)
        f1 = 2 * precision * recall / max(precision + recall, 1e-12)

        if f1 > best_f1:
            best_f1 = f1
            best_prec = precision
            best_rec = recall
            best_thr = thr

    return {
        "precision": best_prec,
        "recall": best_rec,
        "f1": best_f1,
        "best_threshold": best_thr,
        "auc": auc,
    }


def _sample_bce_pairs(
    n_devices: int,
    positive_pairs: torch.Tensor,
    neg_ratio: int = 5,
    device: torch.device | str = "cpu",
) -> tuple[torch.Tensor, torch.Tensor]:
    """Sample positive + negative pairs for BCE training.

    Args:
        n_devices: Number of devices in the graph.
        positive_pairs: (P, 2) ground-truth constraint pair indices.
        neg_ratio: Number of negative pairs per positive pair.
        device: Target device.

    Returns:
        (pair_indices, labels): pair_indices (K, 2), labels (K,) float 0/1.
    """
    pos_set: set[tuple[int, int]] = set()
    for idx in range(positive_pairs.size(0)):
        a, b = int(positive_pairs[idx, 0]), int(positive_pairs[idx, 1])
        pos_set.add((min(a, b), max(a, b)))

    n_pos = len(pos_set)
    n_neg = n_pos * neg_ratio

    # Sample negatives: random pairs that are NOT in the positive set.
    neg_pairs: list[tuple[int, int]] = []
    attempts = 0
    while len(neg_pairs) < n_neg and attempts < n_neg * 10:
        a = int(torch.randint(0, n_devices, (1,)))
        b = int(torch.randint(0, n_devices, (1,)))
        if a == b:
            attempts += 1
            continue
        pair = (min(a, b), max(a, b))
        if pair not in pos_set and pair not in set(neg_pairs):
            neg_pairs.append(pair)
        attempts += 1

    all_pairs = list(pos_set) + neg_pairs
    labels = [1.0] * n_pos + [0.0] * len(neg_pairs)

    pair_t = torch.tensor(all_pairs, dtype=torch.long, device=device)
    label_t = torch.tensor(labels, dtype=torch.float32, device=device)

    # Shuffle.
    perm = torch.randperm(len(all_pairs), device=device)
    return pair_t[perm], label_t[perm]


# ---------------------------------------------------------------------------
# Training -- pairwise loss helper
# ---------------------------------------------------------------------------


def _compute_pairwise_loss(
    embeddings: torch.Tensor,
    positive_pairs: torch.Tensor,
    temperature: float,
    hard_neg_k: int = 16,
    margin: float = 0.0,
) -> torch.Tensor:
    """Compute combined contrastive + logistic pairwise loss + VICReg regularizer.

    Uses NT-Xent contrastive loss as the primary objective, supplemented by
    logistic pairwise loss for margin-based separation and VICReg variance
    regularizer to prevent embedding collapse.

    Efficiently builds a pos_map dict for O(1) partner lookups.

    Args:
        embeddings: (N, D) L2-normalised embeddings.
        positive_pairs: (P, 2) indices of positive pairs.
        temperature: NT-Xent softmax temperature.
        hard_neg_k: Number of hard negatives per anchor.
        margin: ArcFace angular margin for contrastive loss (0.0 to disable).

    Returns:
        Scalar combined loss.
    """
    dev = embeddings.device
    n_dev = embeddings.size(0)

    # NT-Xent contrastive loss (primary) with optional ArcFace margin.
    ntxent = contrastive_loss(
        embeddings, positive_pairs, temperature, hard_neg_k, margin=margin,
    )

    # Logistic pairwise loss (supplementary margin signal).
    sim_matrix = torch.mm(embeddings, embeddings.t())

    pos_map: dict[int, set[int]] = {}
    for pidx in range(positive_pairs.size(0)):
        a, b = int(positive_pairs[pidx, 0]), int(positive_pairs[pidx, 1])
        pos_map.setdefault(a, set()).add(b)
        pos_map.setdefault(b, set()).add(a)

    sims_list: list[torch.Tensor] = []
    labels_list: list[torch.Tensor] = []

    for pidx in range(positive_pairs.size(0)):
        a, b = positive_pairs[pidx, 0], positive_pairs[pidx, 1]
        # Scale raw cosine sim to make logistic loss responsive.
        sims_list.append((sim_matrix[a, b] * 5.0).unsqueeze(0))
        labels_list.append(torch.ones(1, device=dev))

    k = min(hard_neg_k, n_dev - 1)
    for anchor_val, partners in pos_map.items():
        neg_mask = torch.ones(n_dev, device=dev, dtype=torch.bool)
        neg_mask[anchor_val] = False
        for p in partners:
            if p < n_dev:
                neg_mask[p] = False
        neg_sims = sim_matrix[anchor_val][neg_mask]
        if neg_sims.numel() > 0:
            actual_k = min(k, neg_sims.numel())
            topk_negs, _ = torch.topk(neg_sims, actual_k)
            sims_list.append(topk_negs * 5.0)
            labels_list.append(-torch.ones(actual_k, device=dev))

    if sims_list:
        all_sims = torch.cat(sims_list)
        all_labels = torch.cat(labels_list)
        pairwise = logistic_pairwise_loss(all_sims, all_labels)
    else:
        pairwise = torch.tensor(0.0, device=dev, requires_grad=True)

    # VICReg variance regularizer to prevent embedding collapse.
    vicreg = variance_regularizer(embeddings)

    return ntxent + 0.5 * pairwise + 0.1 * vicreg


# ---------------------------------------------------------------------------
# Training
# ---------------------------------------------------------------------------


def train(
    graphs: list[dict[str, torch.Tensor]],
    *,
    epochs: int = 200,
    lr: float = 0.001,
    weight_decay: float = 1e-4,
    temperature: float = 0.05,
    patience: int = 25,
    val_fraction: float = 0.2,
    device: str | torch.device = "cpu",
    checkpoint_dir: str | pathlib.Path = "checkpoints/constraint",
    verbose: bool = True,
    supcon_epochs: int = 0,
    progress_tracker: Callable[[int, float], None] | None = None,
    margin: float = 0.0,
    use_learned_threshold: bool = True,
    bce_finetune_epochs: int = 30,
    mode: str = "bce",
    focal_gamma_pos: float = 0.0,
    focal_gamma_neg: float = 2.0,
    pos_weight: float = 3.0,
    viz: Any = None,
) -> dict[str, Any]:
    """Full training loop with early stopping on validation F1.

    Modes:
        "bce": End-to-end BCE training with EdgeDecoder (recommended).
               GNN encoder + MLP edge decoder trained jointly with BCE loss.
        "contrastive": Legacy contrastive training with cosine threshold.
               Stage 1: Logistic pairwise loss + VICReg.
               Stage 2: Optional SupCon fine-tuning.
               Stage 2b: Optional BCE fine-tuning on cosine similarity.
               Stage 3: Optional learned threshold classifier.

    Args:
        graphs: List of synthetic or real circuit graph dicts.
        epochs: Maximum training epochs for Stage 1.
        lr: Peak Adam learning rate (after warmup).
        weight_decay: L2 regularisation coefficient.
        temperature: Scaling factor for similarity scores.
        patience: Early stopping patience in epochs.
        val_fraction: Fraction of graphs reserved for validation.
        device: Compute device.
        checkpoint_dir: Directory to save the best model checkpoint.
        verbose: Log progress every epoch.
        supcon_epochs: Number of SupCon fine-tuning epochs (Stage 2).
        progress_tracker: Optional callback(epoch, loss) for progress bars.
        margin: ArcFace angular margin (radians) for contrastive loss.
            Set to 0.0 to disable.
        use_learned_threshold: If True, train a learned threshold classifier
            after the main contrastive training loop.
        bce_finetune_epochs: Number of BCE fine-tuning epochs (Stage 2b).
            Only used when supcon_epochs == 0. Set to 0 to disable.

    Returns:
        Dict with keys best_val_f1, epochs_trained, history, checkpoint.
    """
    device = torch.device(device)
    checkpoint_dir = pathlib.Path(checkpoint_dir)
    checkpoint_dir.mkdir(parents=True, exist_ok=True)

    # --- Train / val split ---
    n = len(graphs)
    idx = np.random.default_rng(0).permutation(n)
    n_val = max(1, int(n * val_fraction))
    val_idx, train_idx = idx[:n_val], idx[n_val:]

    train_graphs = [graphs[i] for i in train_idx]
    val_graphs = [graphs[i] for i in val_idx]

    # --- Model / optim ---
    model = build_model(device=device)

    # torch.compile for graph-level kernel fusion (PyTorch 2.0+).
    if hasattr(torch, 'compile'):
        model = torch.compile(model)

    optimiser = torch.optim.Adam(model.parameters(), lr=lr, weight_decay=weight_decay)

    # Helper to get the unwrapped model (torch.compile wraps in OptimizedModule).
    def _unwrapped() -> torch.nn.Module:
        return getattr(model, '_orig_mod', model)

    # --- Mixed precision (AMP) ---
    use_amp = 'cuda' in str(device)
    scaler = torch.amp.GradScaler('cuda', enabled=use_amp)

    # Warmup: linearly ramp LR over first 10% of epochs, then cosine decay.
    warmup_epochs = max(1, epochs // 10)

    def lr_lambda(ep: int) -> float:
        if ep < warmup_epochs:
            return max(0.01, ep / warmup_epochs)
        progress = (ep - warmup_epochs) / max(1, epochs - warmup_epochs)
        return max(0.01, 0.5 * (1.0 + math.cos(math.pi * progress)))

    scheduler = torch.optim.lr_scheduler.LambdaLR(optimiser, lr_lambda)

    # --- Training loop ---
    best_val_f1 = -math.inf
    epochs_no_improve = 0
    history: dict[str, list[float]] = {
        "train_loss": [], "val_f1": [], "val_precision": [],
        "val_recall": [], "val_threshold": [], "val_auc": [],
    }

    epoch = 0
    for epoch in range(1, epochs + 1):
        model.train()
        total_loss = 0.0
        n_graphs_train = 0

        if mode == "bce":
            # --- BCE mode: end-to-end with EdgeDecoder ---
            for g in train_graphs:
                x = g["x"].to(device)
                ei = g["edge_index"].to(device)
                ea = g.get("edge_attr")
                if ea is not None:
                    ea = ea.to(device)
                pp = g["positive_pairs"].to(device)

                if pp.numel() == 0:
                    continue

                n_dev = x.size(0)
                pair_indices, labels = _sample_bce_pairs(n_dev, pp, neg_ratio=5, device=device)

                optimiser.zero_grad()
                with torch.amp.autocast('cuda', enabled=use_amp):
                    logits = _unwrapped().classify_pairs(x, ei, pair_indices, edge_attr=ea)
                    # Focal-weighted BCE for class imbalance.
                    bce = nn.functional.binary_cross_entropy_with_logits(
                        logits, labels, reduction='none',
                    )
                    p_t = labels * torch.sigmoid(logits) + (1 - labels) * (1 - torch.sigmoid(logits))
                    focal_weight = (1 - p_t) ** 2
                    loss = (focal_weight * bce).mean()
                scaler.scale(loss).backward()
                scaler.unscale_(optimiser)
                torch.nn.utils.clip_grad_norm_(model.parameters(), max_norm=1.0)
                scaler.step(optimiser)
                scaler.update()

                total_loss += loss.item()
                n_graphs_train += 1
        else:
            # --- Contrastive mode (legacy) ---
            for g in train_graphs:
                x = g["x"].to(device)
                ei = g["edge_index"].to(device)
                ea = g.get("edge_attr")
                if ea is not None:
                    ea = ea.to(device)
                pp = g["positive_pairs"].to(device)

                if pp.numel() == 0:
                    continue

                optimiser.zero_grad()
                with torch.amp.autocast('cuda', enabled=use_amp):
                    embeddings = model(x, ei, edge_attr=ea, project=True)
                    loss = _compute_pairwise_loss(
                        embeddings, pp, temperature, margin=margin,
                    )
                scaler.scale(loss).backward()
                scaler.unscale_(optimiser)
                torch.nn.utils.clip_grad_norm_(model.parameters(), max_norm=1.0)
                scaler.step(optimiser)
                scaler.update()

                total_loss += loss.item()
                n_graphs_train += 1

        scheduler.step()
        train_loss = total_loss / max(n_graphs_train, 1)

        if progress_tracker is not None:
            progress_tracker(epoch, train_loss)

        # -- validate --
        model.eval()
        all_metrics: list[dict[str, float]] = []
        with torch.no_grad():
            for g in val_graphs:
                x = g["x"].to(device)
                ei = g["edge_index"].to(device)
                ea = g.get("edge_attr")
                if ea is not None:
                    ea = ea.to(device)
                pp = g["positive_pairs"].to(device)

                if mode == "bce":
                    metrics = compute_f1_bce(model, x, ei, pp, edge_attr=ea)
                else:
                    embeddings = model(x, ei, edge_attr=ea, project=False)
                    metrics = compute_f1(embeddings, pp)
                all_metrics.append(metrics)

        val_f1 = float(np.mean([m["f1"] for m in all_metrics])) if all_metrics else 0.0
        val_prec = float(np.mean([m["precision"] for m in all_metrics])) if all_metrics else 0.0
        val_rec = float(np.mean([m["recall"] for m in all_metrics])) if all_metrics else 0.0
        val_thr = float(np.mean([m["best_threshold"] for m in all_metrics])) if all_metrics else 0.5
        val_auc = float(np.mean([m["auc"] for m in all_metrics])) if all_metrics else 0.0

        history["train_loss"].append(train_loss)
        history["val_f1"].append(val_f1)
        history["val_precision"].append(val_prec)
        history["val_recall"].append(val_rec)

        # visualization
        if viz is not None:
            viz.update(epoch, {"train_loss": train_loss, "val_f1": val_f1})
        history["val_threshold"].append(val_thr)
        history["val_auc"].append(val_auc)

        if verbose:
            current_lr = optimiser.param_groups[0]["lr"]
            logger.info(
                "Epoch %3d/%d  train_loss=%.4f  val_F1=%.4f  "
                "val_prec=%.4f  val_rec=%.4f  thr=%.2f  auc=%.4f  lr=%.2e",
                epoch, epochs, train_loss, val_f1,
                val_prec, val_rec, val_thr, val_auc, current_lr,
            )

        # -- checkpoint & early stopping --
        if val_f1 > best_val_f1:
            best_val_f1 = val_f1
            epochs_no_improve = 0
            ckpt = {
                "epoch": epoch,
                "model_state_dict": _unwrapped().state_dict(),
                "optimiser_state_dict": optimiser.state_dict(),
                "val_f1": val_f1,
                "best_threshold": val_thr,
            }
            torch.save(ckpt, checkpoint_dir / "best_model.pt")
        else:
            epochs_no_improve += 1
            if epochs_no_improve >= patience:
                logger.info(
                    "Early stopping at epoch %d (best val F1=%.4f)",
                    epoch, best_val_f1,
                )
                break

    # --- Stage 2: SupCon fine-tuning ---
    if supcon_epochs > 0 and best_val_f1 > 0.1:
        logger.info(
            "Stage 2: SupCon fine-tuning for %d epochs (Stage 1 F1=%.4f)...",
            supcon_epochs, best_val_f1,
        )
        # Load best model from stage 1.
        ckpt = torch.load(
            checkpoint_dir / "best_model.pt", map_location=device, weights_only=True,
        )
        _unwrapped().load_state_dict(ckpt["model_state_dict"])

        # Same temperature, lower LR.
        ft_optimiser = torch.optim.Adam(
            model.parameters(), lr=lr * 0.1, weight_decay=weight_decay,
        )
        ft_scaler = torch.amp.GradScaler('cuda', enabled=use_amp)
        best_ft_f1 = best_val_f1

        for ft_epoch in range(1, supcon_epochs + 1):
            model.train()
            ft_loss_total = 0.0
            n_ft_graphs = 0
            for g in train_graphs:
                x = g["x"].to(device)
                ei = g["edge_index"].to(device)
                ea = g.get("edge_attr")
                if ea is not None:
                    ea = ea.to(device)
                pp = g["positive_pairs"].to(device)

                if pp.numel() == 0:
                    continue

                ft_optimiser.zero_grad()
                with torch.amp.autocast('cuda', enabled=use_amp):
                    embeddings = model(x, ei, edge_attr=ea, project=True)
                    loss = _compute_pairwise_loss(
                        embeddings, pp, temperature, margin=margin,
                    )
                ft_scaler.scale(loss).backward()
                ft_scaler.unscale_(ft_optimiser)
                torch.nn.utils.clip_grad_norm_(model.parameters(), max_norm=1.0)
                ft_scaler.step(ft_optimiser)
                ft_scaler.update()
                ft_loss_total += loss.item()
                n_ft_graphs += 1

            if progress_tracker is not None:
                progress_tracker(
                    epochs + ft_epoch,
                    ft_loss_total / max(n_ft_graphs, 1),
                )

            # Validate.
            model.eval()
            ft_metrics: list[dict[str, float]] = []
            with torch.no_grad():
                for g in val_graphs:
                    x = g["x"].to(device)
                    ei = g["edge_index"].to(device)
                    ea = g.get("edge_attr")
                    if ea is not None:
                        ea = ea.to(device)
                    pp = g["positive_pairs"].to(device)
                    embeddings = model(x, ei, edge_attr=ea, project=False)
                    metrics = compute_f1(embeddings, pp)
                    ft_metrics.append(metrics)

            ft_f1 = float(np.mean([m["f1"] for m in ft_metrics])) if ft_metrics else 0.0
            ft_prec = float(np.mean([m["precision"] for m in ft_metrics])) if ft_metrics else 0.0
            ft_rec = float(np.mean([m["recall"] for m in ft_metrics])) if ft_metrics else 0.0
            ft_thr = float(np.mean([m["best_threshold"] for m in ft_metrics])) if ft_metrics else 0.5

            if verbose and (ft_epoch % 5 == 0 or ft_epoch == 1):
                logger.info(
                    "SupCon %3d/%d  loss=%.4f  val_F1=%.4f  prec=%.4f  rec=%.4f  thr=%.2f",
                    ft_epoch, supcon_epochs,
                    ft_loss_total / max(n_ft_graphs, 1),
                    ft_f1, ft_prec, ft_rec, ft_thr,
                )

            if ft_f1 > best_ft_f1:
                best_ft_f1 = ft_f1
                ckpt = {
                    "epoch": epoch + ft_epoch,
                    "model_state_dict": _unwrapped().state_dict(),
                    "optimiser_state_dict": ft_optimiser.state_dict(),
                    "val_f1": ft_f1,
                    "best_threshold": ft_thr,
                    "stage": "supcon",
                }
                torch.save(ckpt, checkpoint_dir / "best_model.pt")

        best_val_f1 = best_ft_f1
        logger.info("SupCon fine-tuning complete. Best F1: %.4f", best_ft_f1)
    elif supcon_epochs > 0:
        logger.info(
            "Skipping SupCon: Stage 1 F1=%.4f < 0.1 threshold.", best_val_f1,
        )

    # --- Stage 2b: BCE fine-tuning (when SupCon is disabled) ---
    if supcon_epochs == 0 and bce_finetune_epochs > 0 and best_val_f1 > 0.0:
        logger.info(
            "Stage 2b: BCE fine-tuning for %d epochs (Stage 1 F1=%.4f)...",
            bce_finetune_epochs, best_val_f1,
        )
        # Load best model from Stage 1.
        best_ckpt_path = checkpoint_dir / "best_model.pt"
        if best_ckpt_path.exists():
            ckpt_data = torch.load(
                best_ckpt_path, map_location=device, weights_only=True,
            )
            _unwrapped().load_state_dict(ckpt_data["model_state_dict"])

        # Learnable temperature scale for logit = cos_sim * scale.
        bce_scale = nn.Parameter(torch.tensor(10.0, device=device))
        bce_optimiser = torch.optim.Adam(
            list(model.parameters()) + [bce_scale],
            lr=lr * 0.1,
            weight_decay=weight_decay,
        )
        bce_scaler = torch.amp.GradScaler('cuda', enabled=use_amp)
        best_bce_f1 = best_val_f1

        for bce_ep in range(1, bce_finetune_epochs + 1):
            model.train()
            bce_loss_total = 0.0
            n_bce_graphs = 0

            for g in train_graphs:
                x = g["x"].to(device)
                ei = g["edge_index"].to(device)
                ea = g.get("edge_attr")
                if ea is not None:
                    ea = ea.to(device)
                pp = g["positive_pairs"].to(device)

                if pp.numel() == 0:
                    continue

                bce_optimiser.zero_grad()
                with torch.amp.autocast('cuda', enabled=use_amp):
                    embeddings = model(x, ei, edge_attr=ea, project=False)
                    n_nodes = embeddings.size(0)

                    # Positive pairs: compute cosine similarity.
                    pos_a = pp[:, 0]
                    pos_b = pp[:, 1]
                    # Filter valid indices.
                    valid = (pos_a < n_nodes) & (pos_b < n_nodes)
                    pos_a = pos_a[valid]
                    pos_b = pos_b[valid]

                    if pos_a.numel() == 0:
                        continue

                    pos_cos = torch.nn.functional.cosine_similarity(
                        embeddings[pos_a], embeddings[pos_b], dim=-1,
                    )

                    # Sample equal number of negative pairs randomly.
                    n_pos = pos_a.size(0)
                    pos_set: set[tuple[int, int]] = set()
                    for pidx in range(pp.size(0)):
                        a_val, b_val = int(pp[pidx, 0]), int(pp[pidx, 1])
                        if a_val < n_nodes and b_val < n_nodes:
                            pos_set.add((min(a_val, b_val), max(a_val, b_val)))

                    neg_a_list: list[int] = []
                    neg_b_list: list[int] = []
                    # Hard negative mining: prefer same-type, similar-degree pairs
                    # that are NOT positive pairs (topology-confusable negatives).
                    # Get device types from node features (columns 0:6 one-hot).
                    dev_types = x[:, :6].argmax(dim=-1)  # (n_nodes,)
                    # Get degrees from edge index.
                    deg = torch.zeros(n_nodes, device=device)
                    if ei.numel() > 0:
                        deg.scatter_add_(0, ei[0], torch.ones(ei.size(1), device=device))

                    # For each positive pair, find a hard negative of same type
                    hard_neg_budget = n_pos // 2  # Half hard, half random
                    for pidx in range(min(hard_neg_budget, pp.size(0))):
                        anchor = int(pp[pidx, 0])
                        if anchor >= n_nodes:
                            continue
                        anchor_type = int(dev_types[anchor])
                        anchor_deg = float(deg[anchor])
                        # Find same-type devices not in positive set with anchor
                        candidates = []
                        for c in range(n_nodes):
                            if c == anchor or int(dev_types[c]) != anchor_type:
                                continue
                            key = (min(anchor, c), max(anchor, c))
                            if key in pos_set:
                                continue
                            candidates.append((c, abs(float(deg[c]) - anchor_deg)))
                        if candidates:
                            # Pick the one with most similar degree (hardest negative)
                            candidates.sort(key=lambda x: x[1])
                            neg_dev = candidates[0][0]
                            neg_a_list.append(anchor)
                            neg_b_list.append(neg_dev)

                    # Fill remaining with random negatives
                    max_attempts = n_pos * 10
                    attempts = 0
                    remaining = n_pos - len(neg_a_list)
                    while len(neg_a_list) < n_pos and attempts < max_attempts:
                        ra = int(torch.randint(0, n_nodes, (1,)).item())
                        rb = int(torch.randint(0, n_nodes, (1,)).item())
                        if ra != rb:
                            key = (min(ra, rb), max(ra, rb))
                            if key not in pos_set:
                                neg_a_list.append(ra)
                                neg_b_list.append(rb)
                        attempts += 1

                    if not neg_a_list:
                        continue

                    neg_a_t = torch.tensor(neg_a_list, device=device)
                    neg_b_t = torch.tensor(neg_b_list, device=device)
                    neg_cos = torch.nn.functional.cosine_similarity(
                        embeddings[neg_a_t], embeddings[neg_b_t], dim=-1,
                    )

                    # Combine logits and labels.
                    all_cos = torch.cat([pos_cos, neg_cos], dim=0)
                    all_logits = all_cos * bce_scale
                    all_labels = torch.cat([
                        torch.ones(pos_cos.size(0), device=device),
                        torch.zeros(neg_cos.size(0), device=device),
                    ], dim=0)

                    # Asymmetric focal BCE loss — biased toward recall.
                    # gamma_pos=0 (no down-weighting of easy positives — we want ALL positives)
                    # gamma_neg=2 (down-weight easy negatives — focus on hard negatives)
                    # pos_weight=3x (extra emphasis on positive class)
                    bce_raw = torch.nn.functional.binary_cross_entropy_with_logits(
                        all_logits, all_labels, reduction='none',
                    )
                    with torch.no_grad():
                        probs = torch.sigmoid(all_logits)
                        # Asymmetric focal weights
                        is_pos = all_labels > 0.5
                        focal_weight = torch.where(
                            is_pos,
                            (1 - probs) ** focal_gamma_pos,  # = 1.0 for all positives
                            probs ** focal_gamma_neg,         # down-weight easy negatives
                        )
                        # Class imbalance weight: 3x on positives
                        class_weight = torch.where(is_pos, torch.tensor(pos_weight, device=device), torch.tensor(1.0, device=device))
                    loss = (focal_weight * class_weight * bce_raw).mean()

                bce_scaler.scale(loss).backward()
                bce_scaler.unscale_(bce_optimiser)
                torch.nn.utils.clip_grad_norm_(
                    list(model.parameters()) + [bce_scale], max_norm=1.0,
                )
                bce_scaler.step(bce_optimiser)
                bce_scaler.update()
                bce_loss_total += loss.item()
                n_bce_graphs += 1

            if progress_tracker is not None:
                progress_tracker(
                    epochs + bce_ep,
                    bce_loss_total / max(n_bce_graphs, 1),
                )

            # Validate.
            model.eval()
            bce_metrics: list[dict[str, float]] = []
            with torch.no_grad():
                for g in val_graphs:
                    x = g["x"].to(device)
                    ei = g["edge_index"].to(device)
                    ea = g.get("edge_attr")
                    if ea is not None:
                        ea = ea.to(device)
                    pp = g["positive_pairs"].to(device)
                    embeddings = model(x, ei, edge_attr=ea, project=False)
                    metrics = compute_f1(embeddings, pp)
                    bce_metrics.append(metrics)

            bce_f1 = float(np.mean([m["f1"] for m in bce_metrics])) if bce_metrics else 0.0
            bce_prec = float(np.mean([m["precision"] for m in bce_metrics])) if bce_metrics else 0.0
            bce_rec = float(np.mean([m["recall"] for m in bce_metrics])) if bce_metrics else 0.0
            bce_thr = float(np.mean([m["best_threshold"] for m in bce_metrics])) if bce_metrics else 0.5

            if verbose and (bce_ep % 5 == 0 or bce_ep == 1):
                logger.info(
                    "BCE-FT %3d/%d  loss=%.4f  val_F1=%.4f  prec=%.4f  rec=%.4f  thr=%.2f  scale=%.2f",
                    bce_ep, bce_finetune_epochs,
                    bce_loss_total / max(n_bce_graphs, 1),
                    bce_f1, bce_prec, bce_rec, bce_thr, bce_scale.item(),
                )

            if bce_f1 > best_bce_f1:
                best_bce_f1 = bce_f1
                ckpt = {
                    "epoch": epoch + bce_ep,
                    "model_state_dict": _unwrapped().state_dict(),
                    "val_f1": bce_f1,
                    "best_threshold": bce_thr,
                    "stage": "bce_finetune",
                    "bce_scale": bce_scale.item(),
                }
                torch.save(ckpt, checkpoint_dir / "best_model.pt")

        best_val_f1 = best_bce_f1
        logger.info("BCE fine-tuning complete. Best F1: %.4f", best_bce_f1)

    # --- Stage 3: Learned threshold classifier ---
    learned_threshold_f1 = None
    if use_learned_threshold and best_val_f1 > 0.0:
        logger.info("Stage 3: Training learned threshold classifier...")

        # Load best GNN checkpoint for classifier training.
        best_ckpt_path = checkpoint_dir / "best_model.pt"
        if best_ckpt_path.exists():
            ckpt_data = torch.load(
                best_ckpt_path, map_location=device, weights_only=True,
            )
            _unwrapped().load_state_dict(ckpt_data["model_state_dict"])

        classifier = train_learned_threshold(
            model, val_graphs, device, verbose=verbose,
        )

        # Evaluate with learned threshold on validation set.
        lt_metrics = evaluate_with_learned_threshold(
            model, classifier, val_graphs, device,
        )
        learned_threshold_f1 = lt_metrics["f1"]
        logger.info(
            "Learned threshold classifier val F1=%.4f  "
            "(threshold-sweep F1=%.4f)",
            learned_threshold_f1, best_val_f1,
        )

        # Save classifier alongside GNN checkpoint.
        classifier_ckpt = {
            "classifier_state_dict": classifier.state_dict(),
            "learned_threshold_f1": learned_threshold_f1,
        }
        torch.save(classifier_ckpt, checkpoint_dir / "pair_classifier.pt")
        logger.info(
            "Saved pair classifier to %s",
            checkpoint_dir / "pair_classifier.pt",
        )

    result = {
        "best_val_f1": best_val_f1,
        "epochs_trained": epoch,
        "history": history,
        "checkpoint": str(checkpoint_dir / "best_model.pt"),
    }
    if learned_threshold_f1 is not None:
        result["learned_threshold_f1"] = learned_threshold_f1
        result["classifier_checkpoint"] = str(
            checkpoint_dir / "pair_classifier.pt"
        )
    return result


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------


def main() -> None:
    """CLI entry point: generate synthetic data and launch constraint training."""
    logging.basicConfig(level=logging.INFO, format="%(levelname)s: %(message)s")

    parser = argparse.ArgumentParser(description="Train GNN Constraint Predictor")
    parser.add_argument("--n-graphs", type=int, default=500)
    parser.add_argument("--epochs", type=int, default=200)
    parser.add_argument("--lr", type=float, default=0.001)
    parser.add_argument("--temperature", type=float, default=0.05)
    parser.add_argument("--patience", type=int, default=25)
    parser.add_argument("--device", type=str, default="cpu")
    parser.add_argument(
        "--checkpoint-dir", type=str, default="checkpoints/constraint"
    )
    parser.add_argument("--supcon-epochs", type=int, default=0)
    parser.add_argument("--margin", type=float, default=0.0,
                        help="ArcFace angular margin for contrastive loss (0.0 to disable)")
    parser.add_argument("--use-learned-threshold", type=bool, default=True,
                        help="Train a learned threshold classifier after GNN training")
    parser.add_argument("--no-learned-threshold", dest="use_learned_threshold",
                        action="store_false",
                        help="Disable learned threshold classifier")
    parser.add_argument("--bce-finetune-epochs", type=int, default=30,
                        help="BCE fine-tuning epochs (Stage 2b, when --supcon-epochs=0). 0 to disable.")
    parser.add_argument("--mode", type=str, default="bce", choices=["bce", "contrastive"],
                        help="Training mode: 'bce' (end-to-end EdgeDecoder) or 'contrastive' (legacy)")
    parser.add_argument("--focal-gamma-pos", type=float, default=0.0, help="Focal gamma for positive class (0=no down-weight)")
    parser.add_argument("--focal-gamma-neg", type=float, default=2.0, help="Focal gamma for negative class")
    parser.add_argument("--pos-weight", type=float, default=3.0, help="Class weight multiplier for positive pairs")
    parser.add_argument("--verbose", action="store_true", default=True)
    parser.add_argument("--data-dir", type=str, default=None,
                        help="Directory of real SPICE netlists. When provided, "
                             "load real circuit data instead of (or in addition to) "
                             "synthetic data. Use --data-dir-only to skip synthetic.")
    parser.add_argument("--data-dir-only", action="store_true", default=False,
                        help="When --data-dir is set, use ONLY real data (no synthetic).")
    # visualization
    parser.add_argument(
        "--viz",
        action="store_true",
        default=False,
        help="Enable training visualization (saves PNG plots; live window if DISPLAY is set).",
    )
    args = parser.parse_args()

    if args.data_dir:
        real_graphs = load_real_circuit_data(args.data_dir)
        if args.data_dir_only:
            graphs = real_graphs
            if not graphs:
                logger.error("No real circuit graphs loaded from %s. Exiting.", args.data_dir)
                return
        else:
            synth_graphs = load_or_generate_dataset(n_graphs=args.n_graphs)
            graphs = real_graphs + synth_graphs
            logger.info(
                "Combined dataset: %d real + %d synthetic = %d total graphs",
                len(real_graphs), len(synth_graphs), len(graphs),
            )
    else:
        graphs = load_or_generate_dataset(n_graphs=args.n_graphs)

    # Verbose: print cosine similarity distribution analysis for first graph.
    if args.verbose and graphs:
        g = graphs[0]
        x = g["x"]
        pp = g["positive_pairs"]

        norms = x.norm(dim=-1, keepdim=True).clamp(min=1e-8)
        dev_normed = x / norms
        raw_sim = torch.mm(dev_normed, dev_normed.t())

        n = dev_normed.size(0)
        row, col = torch.triu_indices(n, n, offset=1)
        all_sims = raw_sim[row, col]

        # Positive pair similarities.
        pos_sims = []
        for idx in range(pp.size(0)):
            a, b = int(pp[idx, 0]), int(pp[idx, 1])
            if a < n and b < n:
                pos_sims.append(float(raw_sim[a, b]))

        logger.info("--- Raw Feature Cosine Similarity Analysis ---")
        logger.info(
            "  All pairs:     mean=%.4f  std=%.4f  min=%.4f  max=%.4f",
            all_sims.mean(), all_sims.std(), all_sims.min(), all_sims.max(),
        )
        if pos_sims:
            ps = torch.tensor(pos_sims)
            logger.info(
                "  Positive pairs: mean=%.4f  std=%.4f  min=%.4f  max=%.4f",
                ps.mean(), ps.std(), ps.min(), ps.max(),
            )
        logger.info(
            "  Fraction of all pairs with sim > 0.8: %.4f",
            float((all_sims > 0.8).float().mean()),
        )
        logger.info("--- End Similarity Analysis ---")

    # visualization
    _viz = None
    if args.viz and _TrainingVisualizer is not None:
        import os as _os
        _viz = _TrainingVisualizer(
            model_name="constraint",
            metrics=["train_loss", "val_f1"],
            output_dir=args.checkpoint_dir,
            save_every=10,
            live=bool(_os.environ.get("DISPLAY") or _os.environ.get("WAYLAND_DISPLAY")),
        )

    result = train(
        graphs,
        epochs=args.epochs,
        lr=args.lr,
        temperature=args.temperature,
        patience=args.patience,
        device=args.device,
        checkpoint_dir=args.checkpoint_dir,
        supcon_epochs=args.supcon_epochs,
        margin=args.margin,
        use_learned_threshold=args.use_learned_threshold,
        bce_finetune_epochs=args.bce_finetune_epochs,
        mode=args.mode,
        focal_gamma_pos=args.focal_gamma_pos,
        focal_gamma_neg=args.focal_gamma_neg,
        pos_weight=args.pos_weight,
        viz=_viz,
    )

    # visualization
    if _viz is not None:
        _viz.finish()

    logger.info("Training complete. Best val F1: %.4f", result["best_val_f1"])
    logger.info("Checkpoint saved to: %s", result["checkpoint"])
    if "learned_threshold_f1" in result:
        logger.info(
            "Learned threshold F1: %.4f  (classifier: %s)",
            result["learned_threshold_f1"],
            result.get("classifier_checkpoint", "N/A"),
        )


# ---------------------------------------------------------------------------
# Inference bridge -- called from pipeline.py
# ---------------------------------------------------------------------------

# Default checkpoint path relative to the project root.
_DEFAULT_CHECKPOINT = "checkpoints/constraint/best_model.pt"


def _find_checkpoint() -> pathlib.Path:
    """Locate the constraint model checkpoint, searching from this file upward.

    Returns:
        Path to the checkpoint file (may not exist if not yet trained).
    """
    # Walk up from this file to find the project root (contains build.zig).
    current = pathlib.Path(__file__).resolve().parent
    for _ in range(10):
        candidate = current / _DEFAULT_CHECKPOINT
        if candidate.exists():
            return candidate
        if (current / "build.zig").exists():
            # We found the project root; the checkpoint should be here.
            return candidate
        parent = current.parent
        if parent == current:
            break
        current = parent
    return pathlib.Path(_DEFAULT_CHECKPOINT)


def _build_device_features(arrays: dict) -> np.ndarray:
    """Build the 16-dim per-device feature matrix from the FFI arrays dict.

    Feature layout (matches DEVICE_FEAT_DIM = 16):
        [0:6]   device type one-hot  (6 classes)
        [6]     W
        [7]     L
        [8]     fingers (as float)
        [9]     mult (as float)
        [10]    x position
        [11]    y position
        [12:16] structural fingerprint (4 dims)

    Args:
        arrays: Dict from ``SpoutFFI.get_all_arrays()``.

    Returns:
        float32 array of shape (num_devices, 16).
    """
    num_devices = int(arrays["num_devices"])
    features = np.zeros((num_devices, DEVICE_FEAT_DIM), dtype=np.float32)

    # One-hot encode device types (clamp to [0, 5]).
    device_types = arrays["device_types"]  # (N,) uint8
    for i in range(num_devices):
        t = int(device_types[i]) if i < len(device_types) else 0
        t = min(t, 5)
        features[i, t] = 1.0

    # Device parameters: (N, 5) with columns [W, L, fingers_f32, mult_f32, value].
    device_params = arrays["device_params"]  # (N, 5) float32
    if device_params.shape[0] > 0:
        features[:, 6] = device_params[:, 0]   # W
        features[:, 7] = device_params[:, 1]   # L
        features[:, 8] = device_params[:, 2]   # fingers
        features[:, 9] = device_params[:, 3]   # mult

    # Positions: (N, 2) float32.
    positions = arrays["device_positions"]  # (N, 2) float32
    if positions.shape[0] > 0:
        features[:, 10] = positions[:, 0]  # x
        features[:, 11] = positions[:, 1]  # y

    # Structural fingerprint from pin connectivity.
    pin_device = arrays["pin_device"]
    pin_net = arrays["pin_net"]
    pin_terminal = arrays.get(
        "pin_terminal", np.zeros(len(pin_device), dtype=np.uint8)
    )

    pins = []
    for p in range(len(pin_device)):
        dev = int(pin_device[p])
        net = int(pin_net[p])
        term = int(pin_terminal[p]) if p < len(pin_terminal) else 0
        term = min(term, 2)  # fingerprint only uses gate/drain/source (0-2)
        pins.append((dev, net, term))

    if pins:
        struct_fp = compute_structural_fingerprint(num_devices, pins)
        features[:, 12:16] = struct_fp

    return features


def _build_edge_index_and_attr(arrays: dict) -> tuple[np.ndarray, np.ndarray]:
    """Build device-device edge_index (2, E) and edge_attr (E, 5) from pin connectivity.

    Creates a device-only graph where edges connect devices sharing nets.
    Edge features: [gate_shared, drain_shared, source_shared, body_shared,
    n_shared_nets_normalized].

    Args:
        arrays: Dict from ``SpoutFFI.get_all_arrays()``.

    Returns:
        (edge_index, edge_attr): int64 (2, E) and float32 (E, 5).
    """
    num_devices = int(arrays["num_devices"])
    pin_device = arrays["pin_device"]
    pin_net = arrays["pin_net"]
    pin_terminal = arrays.get(
        "pin_terminal", np.zeros(len(pin_device), dtype=np.uint8)
    )

    pins = []
    for p in range(len(pin_device)):
        dev = int(pin_device[p])
        net = int(pin_net[p])
        term = int(pin_terminal[p]) if p < len(pin_terminal) else 0
        term = min(term, 3)
        pins.append((dev, net, term))

    return _build_device_graph_from_pins(num_devices, pins)


def _build_edge_index(arrays: dict) -> np.ndarray:
    """Build a COO edge index (2, E) from pin connectivity (backward compat).

    Creates edges between devices that share a common net, using the
    pin_device and pin_net arrays.

    Args:
        arrays: Dict from ``SpoutFFI.get_all_arrays()``.

    Returns:
        int64 array of shape (2, E) with bidirectional device-device edges.
    """
    pin_device = arrays["pin_device"]  # (P,) uint32
    pin_net = arrays["pin_net"]        # (P,) uint32

    # Group pins by net, then create edges between all device pairs on each net.
    net_to_devices: dict[int, list[int]] = defaultdict(list)
    for p in range(len(pin_device)):
        net_id = int(pin_net[p])
        dev_id = int(pin_device[p])
        net_to_devices[net_id].append(dev_id)

    src_list: list[int] = []
    dst_list: list[int] = []
    for _net_id, devs in net_to_devices.items():
        unique_devs = list(set(devs))
        for i in range(len(unique_devs)):
            for j in range(i + 1, len(unique_devs)):
                # Add both directions for undirected graph.
                src_list.append(unique_devs[i])
                dst_list.append(unique_devs[j])
                src_list.append(unique_devs[j])
                dst_list.append(unique_devs[i])

    if not src_list:
        return np.zeros((2, 0), dtype=np.int64)

    return np.array([src_list, dst_list], dtype=np.int64)


def encode_circuit(arrays: dict) -> tuple[np.ndarray, np.ndarray]:
    """Encode a circuit into device and net embeddings using the trained model.

    Args:
        arrays: Dict from ``SpoutFFI.get_all_arrays()``.  Expected keys:
            device_positions, device_types, device_params, net_fanout,
            pin_device, pin_net, pin_terminal, num_devices, num_nets, num_pins.

    Returns:
        (device_embeddings, net_embeddings):
            device_embeddings -- np.ndarray of shape (num_devices, 64), float32.
            net_embeddings    -- np.ndarray of shape (num_nets, 64), float32.

    Raises:
        FileNotFoundError: If the checkpoint file does not exist.
        RuntimeError: If model loading or inference fails.
    """
    num_devices = int(arrays["num_devices"])
    num_nets = int(arrays["num_nets"])

    # --- Load checkpoint ---
    ckpt_path = _find_checkpoint()
    if not ckpt_path.exists():
        raise FileNotFoundError(
            f"Constraint model checkpoint not found at {ckpt_path}"
        )

    dev = torch.device("cuda" if torch.cuda.is_available() else "cpu")
    ckpt = torch.load(ckpt_path, map_location=dev, weights_only=True)

    model = build_model(device=dev)
    # Handle both old (2-layer) and new (3-layer) checkpoints.
    try:
        model.load_state_dict(ckpt["model_state_dict"])
    except RuntimeError:
        model.load_state_dict(ckpt["model_state_dict"], strict=False)
    model.eval()

    # --- Build device-only graph with edge features ---
    x_np = _build_device_features(arrays)
    edge_index_np, edge_attr_np = _build_edge_index_and_attr(arrays)

    x = torch.from_numpy(x_np).to(dev)
    edge_index = torch.from_numpy(edge_index_np).to(dev)
    edge_attr = torch.from_numpy(edge_attr_np).to(dev)

    # --- Inference ---
    with torch.no_grad():
        device_embeddings = model(
            x, edge_index, edge_attr=edge_attr, project=False,
        )

    device_emb_np = device_embeddings.cpu().numpy().astype(np.float32)

    # --- Net embeddings ---
    # Aggregate device embeddings per net to produce net-level embeddings.
    net_emb_np = np.zeros((num_nets, 64), dtype=np.float32)
    pin_device_arr = arrays["pin_device"]
    pin_net_arr = arrays["pin_net"]

    if len(pin_device_arr) > 0 and len(pin_net_arr) > 0:
        net_to_devs: dict[int, list[int]] = defaultdict(list)
        for p in range(len(pin_device_arr)):
            net_id = int(pin_net_arr[p])
            dev_id = int(pin_device_arr[p])
            if net_id < num_nets and dev_id < num_devices:
                net_to_devs[net_id].append(dev_id)

        for net_id, dev_ids in net_to_devs.items():
            unique_ids = list(set(dev_ids))
            if unique_ids:
                net_emb_np[net_id] = device_emb_np[unique_ids].mean(axis=0)

    logger.info(
        "encode_circuit: device_emb %s, net_emb %s",
        device_emb_np.shape,
        net_emb_np.shape,
    )
    return device_emb_np, net_emb_np


if __name__ == "__main__":
    main()
