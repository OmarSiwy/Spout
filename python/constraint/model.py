"""Constraint GNN for symmetry and matching prediction.

Essential model steps:
    1. Encode device features and connectivity into per-device embeddings.
    2. Optionally project or normalize the embeddings for the training mode.
    3. Score candidate device pairs with a lightweight decoder.

Optimization rationale:
    - LayerNorm is used instead of BatchNorm to keep small-graph batches
      stable during training.
    - Edge-aware attention layers keep graph context in the encoder so the
      pair decoder can stay simple and inexpensive.
"""

from __future__ import annotations

import torch
import torch.nn as nn
import torch.nn.functional as F
from torch_geometric.nn import GATv2Conv


# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

DEVICE_FEAT_DIM = 16  # ParaGraph device features (12) + structural fingerprint (4)


# ---------------------------------------------------------------------------
# Edge Decoder
# ---------------------------------------------------------------------------


class EdgeDecoder(nn.Module):
    """MLP decoder that classifies device pairs from concatenated embeddings.

    Input: concat(z_u, z_v, |z_u - z_v|) -> 3*embed_dim features.
    Output: probability that the pair is a constraint.
    """

    def __init__(self, embed_dim: int = 64, hidden_dim: int = 64, dropout: float = 0.1) -> None:
        super().__init__()
        self.net = nn.Sequential(
            nn.Linear(embed_dim * 3, hidden_dim),
            nn.ReLU(inplace=True),
            nn.Dropout(dropout),
            nn.Linear(hidden_dim, hidden_dim // 2),
            nn.ReLU(inplace=True),
            nn.Linear(hidden_dim // 2, 1),
        )

    def forward(self, z_u: torch.Tensor, z_v: torch.Tensor) -> torch.Tensor:
        """Return logits (pre-sigmoid) for each pair.

        Args:
            z_u: (K, D) embeddings of first device in each pair.
            z_v: (K, D) embeddings of second device in each pair.

        Returns:
            (K,) logits.
        """
        # Step 1: build pairwise features from the two embeddings.
        feat = torch.cat([z_u, z_v, (z_u - z_v).abs()], dim=-1)
        # Step 2: decode a constraint logit for the pair.
        return self.net(feat).squeeze(-1)

    def predict_proba(self, z_u: torch.Tensor, z_v: torch.Tensor) -> torch.Tensor:
        """Return sigmoid probabilities for each pair."""
        return torch.sigmoid(self.forward(z_u, z_v))


# ---------------------------------------------------------------------------
# Model
# ---------------------------------------------------------------------------


class ConstraintGraphSAGE(nn.Module):
    """Three-stage graph encoder for device-constraint prediction.

    Essential model steps:
        1. Aggregate graph context with edge-aware attention layers.
        2. Fuse the raw-device skip path after the first message-passing stage.
        3. Produce embeddings for either contrastive training or pair decoding.
    """

    def __init__(
        self,
        in_features: int = DEVICE_FEAT_DIM,
        hidden_dim: int = 128,
        embed_dim: int = 64,
        dropout: float = 0.1,
        edge_dim: int = 5,
    ) -> None:
        super().__init__()
        self.edge_dim = edge_dim
        self.embed_dim = embed_dim

        # Optimization rationale: self-loops keep isolated devices trainable.
        self.conv1 = GATv2Conv(
            in_features, hidden_dim // 4, heads=4, concat=True,
            edge_dim=edge_dim, add_self_loops=True,
        )
        self.ln1 = nn.LayerNorm(hidden_dim)

        self.conv2 = GATv2Conv(
            hidden_dim, hidden_dim // 4, heads=4, concat=True,
            edge_dim=edge_dim, add_self_loops=True,
        )
        self.ln2 = nn.LayerNorm(hidden_dim)

        self.conv3 = GATv2Conv(
            hidden_dim, embed_dim, heads=1, concat=False,
            edge_dim=edge_dim, add_self_loops=True,
        )
        self.ln3 = nn.LayerNorm(embed_dim)

        self.dropout = nn.Dropout(p=dropout)

        # Optimization rationale: the projected skip path preserves raw device
        # information when the graph signal is sparse.
        self.skip_proj = nn.Linear(in_features, hidden_dim)

        # Optimization rationale: the projection head is only needed for the
        # legacy contrastive objective, so it stays optional at inference time.
        self.projection = nn.Sequential(
            nn.Linear(embed_dim, embed_dim // 2),
            nn.ReLU(inplace=True),
            nn.Linear(embed_dim // 2, embed_dim),
        )

        # Edge decoder for direct pair classification.
        self.edge_decoder = EdgeDecoder(embed_dim=embed_dim)

        self._init_weights()

    def _init_weights(self) -> None:
        """Initialise linear layers with Kaiming normal and layer norms to identity."""
        for m in self.modules():
            if isinstance(m, nn.Linear):
                nn.init.kaiming_normal_(m.weight, nonlinearity="relu")
                if m.bias is not None:
                    nn.init.zeros_(m.bias)

    def forward(
        self,
        x: torch.Tensor,
        edge_index: torch.Tensor,
        edge_attr: torch.Tensor | None = None,
        project: bool = False,
        normalize: bool = True,
    ) -> torch.Tensor:
        """Produce per-device embeddings.

        Args:
            x: (N, in_features) node feature matrix.
            edge_index: (2, E) COO edge index.
            edge_attr: (E, edge_dim) edge feature matrix, or None.
            project: If True, apply the projection head (contrastive mode).
            normalize: If True, L2-normalise embeddings (contrastive mode).
                Set to False for BCE training with EdgeDecoder.

        Returns:
            (N, embed_dim) embeddings.
        """
        # Step 1: preserve a projected copy of the raw device features.
        skip = self.skip_proj(x)

        # Step 2: propagate information across the device graph.
        h = self.conv1(x, edge_index, edge_attr=edge_attr)
        h = self.ln1(h)
        h = F.relu(h, inplace=True)
        h = self.dropout(h)

        # Step 3: fuse the raw-device skip path back into the hidden state.
        h = h + skip

        # Step 4: refine the embedding with deeper graph context.
        h = self.conv2(h, edge_index, edge_attr=edge_attr)
        h = self.ln2(h)
        h = F.relu(h, inplace=True)
        h = self.dropout(h)

        # Step 5: project the graph state into the final embedding space.
        h = self.conv3(h, edge_index, edge_attr=edge_attr)
        h = self.ln3(h)
        h = F.relu(h, inplace=True)

        # Step 6: optionally project or normalise the final embeddings.
        if project:
            h = self.projection(h)

        if normalize:
            h = F.normalize(h, p=2, dim=-1)
        return h

    def classify_pairs(
        self,
        x: torch.Tensor,
        edge_index: torch.Tensor,
        pair_indices: torch.Tensor,
        edge_attr: torch.Tensor | None = None,
    ) -> torch.Tensor:
        """End-to-end pair classification: GNN encoder + EdgeDecoder.

        Args:
            x: (N, in_features) node features.
            edge_index: (2, E) COO edge index.
            pair_indices: (K, 2) device pair indices to classify.
            edge_attr: (E, edge_dim) optional edge features.

        Returns:
            (K,) logits (pre-sigmoid) for each pair.
        """
        embeddings = self.forward(x, edge_index, edge_attr=edge_attr, normalize=False)
        z_u = embeddings[pair_indices[:, 0]]
        z_v = embeddings[pair_indices[:, 1]]
        return self.edge_decoder(z_u, z_v)


# ---------------------------------------------------------------------------
# Loss
# ---------------------------------------------------------------------------


def contrastive_loss(
    embeddings: torch.Tensor,
    positive_pairs: torch.Tensor,
    temperature: float = 0.2,
    hard_neg_k: int = 32,
    margin: float = 0.0,
) -> torch.Tensor:
    """NT-Xent-style contrastive loss with hard negative mining and ArcFace margin.

    For each anchor in a positive pair, selects the top-K hardest negatives
    (highest similarity to anchor among non-positive nodes) to compute the
    denominator, rather than using all N nodes.

    When margin > 0, applies an ArcFace-style angular margin penalty to
    positive similarities: cos(arccos(sim) + margin). This forces positive
    pairs to achieve higher true similarity to receive the same loss credit,
    spreading embeddings further apart in angular space.

    Args:
        embeddings: (N, D) L2-normalised embeddings.
        positive_pairs: (P, 2) indices of positive (symmetry/matching) pairs.
        temperature: softmax temperature.
        hard_neg_k: number of hard negatives to mine per anchor.
        margin: ArcFace angular margin (radians) applied to positive pairs.
            Set to 0.0 to disable (backward-compatible default).

    Returns:
        Scalar loss.
    """
    if positive_pairs.numel() == 0:
        return torch.tensor(0.0, device=embeddings.device, requires_grad=True)

    n = embeddings.size(0)

    # Full similarity matrix (raw cosine, before temperature scaling).
    raw_sim = torch.mm(embeddings, embeddings.t())

    # Build a set of positive partners for each node for masking.
    pos_map: dict[int, set[int]] = {}
    for idx in range(positive_pairs.size(0)):
        i_val = int(positive_pairs[idx, 0])
        j_val = int(positive_pairs[idx, 1])
        pos_map.setdefault(i_val, set()).add(j_val)
        pos_map.setdefault(j_val, set()).add(i_val)

    loss = torch.tensor(0.0, device=embeddings.device)
    n_terms = 0

    for idx in range(positive_pairs.size(0)):
        i, j = positive_pairs[idx, 0], positive_pairs[idx, 1]

        for anchor, pos in [(i, j), (j, i)]:
            anchor_int = int(anchor)
            pos_partners = pos_map.get(anchor_int, set())

            # Mask: exclude self and all positive partners.
            neg_mask = torch.ones(n, device=embeddings.device, dtype=torch.bool)
            neg_mask[anchor_int] = False
            for p in pos_partners:
                if p < n:
                    neg_mask[p] = False

            neg_sims_raw = raw_sim[anchor][neg_mask]

            if neg_sims_raw.numel() == 0:
                continue

            # Temperature-scaled negative similarities.
            neg_sims = neg_sims_raw / temperature

            # Hard negative mining: take top-K hardest negatives.
            k = min(hard_neg_k, neg_sims.numel())
            hard_negs, _ = torch.topk(neg_sims, k)

            # Positive similarity with optional ArcFace angular margin.
            pos_cos = raw_sim[anchor, pos]
            if margin > 0.0:
                # ArcFace: cos(arccos(cos_theta) + margin)
                eps = 1e-6
                pos_cos_clamped = torch.clamp(pos_cos, -1.0 + eps, 1.0 - eps)
                theta = torch.acos(pos_cos_clamped)
                pos_cos = torch.cos(theta + margin)
            pos_sim = (pos_cos / temperature).unsqueeze(0)

            # logsumexp over positive + hard negatives.
            all_logits = torch.cat([pos_sim, hard_negs])
            loss_term = -pos_sim[0] + torch.logsumexp(all_logits, dim=0)

            loss = loss + loss_term
            n_terms += 1

    if n_terms == 0:
        return torch.tensor(0.0, device=embeddings.device, requires_grad=True)

    return loss / n_terms


# ---------------------------------------------------------------------------
# Convenience helpers
# ---------------------------------------------------------------------------


def build_model(
    device: torch.device | str = "cpu",
    **kwargs,
) -> ConstraintGraphSAGE:
    """Create a ConstraintGraphSAGE and move it to the specified device.

    Args:
        device: Target device (e.g. "cpu", "cuda").
        **kwargs: Forwarded to ConstraintGraphSAGE.__init__.

    Returns:
        Initialised model on the requested device.
    """
    model = ConstraintGraphSAGE(**kwargs)
    return model.to(device)


def predict_constraints(
    model: ConstraintGraphSAGE,
    x: torch.Tensor,
    edge_index: torch.Tensor,
    threshold: float = 0.5,
    edge_attr: torch.Tensor | None = None,
    use_fp16: bool = False,
) -> tuple[torch.Tensor, torch.Tensor]:
    """Run inference and return predicted constraint pairs.

    Uses the EdgeDecoder for classification (threshold on sigmoid probability).

    Args:
        model: Trained ConstraintGraphSAGE.
        x: (N, in_features) node features.
        edge_index: (2, E) graph edges.
        threshold: Probability threshold for predicting a constraint.
        edge_attr: (E, edge_dim) optional edge features.
        use_fp16: Use FP16 inference for ~2x speedup.

    Returns:
        (pairs, scores): pairs is (K, 2) tensor of predicted constraint pairs,
        scores is (K,) tensor of their probabilities.
    """
    model.eval()
    if use_fp16 and x.is_cuda:
        model = model.half()
        x = x.half()
    with torch.no_grad():
        embeddings = model(x, edge_index, edge_attr=edge_attr, normalize=False)

        # Evaluate all upper-triangular pairs through the edge decoder.
        n = embeddings.size(0)
        row, col = torch.triu_indices(n, n, offset=1, device=embeddings.device)
        z_u = embeddings[row]
        z_v = embeddings[col]
        scores = model.edge_decoder.predict_proba(z_u, z_v)

        mask = scores >= threshold
        pairs = torch.stack([row[mask], col[mask]], dim=1)
        scores = scores[mask]

    return pairs, scores


if __name__ == "__main__":
    model = build_model()
    print(model)

    # Smoke test.
    n_nodes, n_edges = 30, 90
    x = torch.randn(n_nodes, DEVICE_FEAT_DIM)
    edge_index = torch.randint(0, n_nodes, (2, n_edges))
    edge_attr = torch.randn(n_edges, 5)

    # Test BCE mode (no normalization).
    embeddings = model(x, edge_index, edge_attr, normalize=False)
    print(f"Input shape:     {x.shape}")
    print(f"Embedding shape: {embeddings.shape}")

    # Test classify_pairs.
    pair_idx = torch.tensor([[0, 1], [2, 3], [4, 5]])
    logits = model.classify_pairs(x, edge_index, pair_idx, edge_attr=edge_attr)
    print(f"Pair logits:     {logits.shape} -> {logits}")

    pairs, scores = predict_constraints(model, x, edge_index, edge_attr=edge_attr)
    print(f"Predicted pairs: {pairs.shape[0]}")

    total_params = sum(p.numel() for p in model.parameters())
    print(f"Total parameters: {total_params:,}")
