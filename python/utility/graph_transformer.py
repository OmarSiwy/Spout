"""Graph Transformer Actor-Critic for placement (2c-4).

A 6-layer Graph Transformer with:
  - Edge-biased multi-head attention (edge features modulate attention scores)
  - Spectral positional encoding (Laplacian eigenvectors)
  - ~2.5M parameters (vs ~130K for the GCN baseline)
  - O(N^2) attention, acceptable for N < 100 typical analog circuits

Hybrid integration: the Transformer produces an initial placement seed,
then the Zig SA engine refines it locally.

Architecture:
    SpectralPE(k=8) + NodeProjection -> 6x GraphTransformerLayer
    -> global_pool + device_emb -> Actor(grid logits) + Critic(value)
"""

from __future__ import annotations

import math

import torch
import torch.nn as nn
import torch.nn.functional as F


# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

DEVICE_FEAT_DIM = 12   # type one-hot(6) + W, L, fingers, mult, x, y
STATE_FEAT_DIM = 4     # placed flag, grid_x, grid_y, step_fraction
NODE_FEAT_DIM = DEVICE_FEAT_DIM + STATE_FEAT_DIM  # 16
GRID_SIZE = 16
NUM_ACTIONS = GRID_SIZE * GRID_SIZE  # 256
SPECTRAL_PE_DIM = 8   # number of Laplacian eigenvectors
EDGE_FEAT_DIM = 4     # edge features: distance, shared_nets, weight_type, fanout


# ---------------------------------------------------------------------------
# Spectral Positional Encoding
# ---------------------------------------------------------------------------


class SpectralPositionalEncoding(nn.Module):
    """Laplacian eigenvector positional encoding.

    Computes the k smallest non-trivial eigenvectors of the graph Laplacian
    and projects them through a learnable linear layer.  This gives each
    node a position-aware embedding that captures graph structure beyond
    immediate neighbours.

    Reference: Dwivedi & Bresson, "A Generalization of Transformer Networks
    to Graphs", AAAI 2021 Workshop.
    """

    def __init__(self, k: int = SPECTRAL_PE_DIM, d_model: int = 64) -> None:
        super().__init__()
        self.k = k
        self.linear = nn.Linear(k, d_model)

    @staticmethod
    def _compute_laplacian_pe(
        edge_index: torch.Tensor,
        num_nodes: int,
        k: int,
    ) -> torch.Tensor:
        """Compute k smallest non-trivial Laplacian eigenvectors.

        Returns shape (num_nodes, k).  Padded with zeros if the graph has
        fewer than k+1 eigenvalues.
        """
        device = edge_index.device

        # Build adjacency matrix (undirected).
        row, col = edge_index[0], edge_index[1]
        # Remove self-loops and duplicate edges.
        mask = row != col
        row, col = row[mask], col[mask]

        # Build sparse adjacency.
        adj = torch.zeros(num_nodes, num_nodes, device=device, dtype=torch.float32)
        if row.numel() > 0:
            adj[row, col] = 1.0
            adj[col, row] = 1.0  # ensure symmetry

        # Degree matrix and Laplacian.
        deg = adj.sum(dim=1)
        deg_inv_sqrt = torch.where(
            deg > 0, 1.0 / torch.sqrt(deg), torch.zeros_like(deg)
        )
        D_inv_sqrt = torch.diag(deg_inv_sqrt)

        # Normalised Laplacian: I - D^{-1/2} A D^{-1/2}
        L = torch.eye(num_nodes, device=device) - D_inv_sqrt @ adj @ D_inv_sqrt

        # Eigendecomposition: use LOBPCG for partial decomp (10-56x faster for N > k).
        try:
            # LOBPCG is 10-56x faster for partial eigendecomposition (PEARL, ICLR 2025)
            X0 = torch.randn(num_nodes, k + 1, device=device)
            eigenvalues, eigenvectors = torch.lobpcg(L, k=k + 1, X=X0, largest=False, niter=20)
        except Exception:
            # Fallback to full eigendecomposition for very small graphs
            try:
                eigenvalues, eigenvectors = torch.linalg.eigh(L)
            except Exception:
                return torch.zeros(num_nodes, k, device=device)

        # Skip the first eigenvector (constant, eigenvalue ~0).
        # Take the next k eigenvectors.
        n_available = min(eigenvectors.shape[1] - 1, k)
        if n_available <= 0:
            return torch.zeros(num_nodes, k, device=device)

        pe = eigenvectors[:, 1 : 1 + n_available]

        # Pad if fewer than k eigenvectors available.
        if n_available < k:
            padding = torch.zeros(
                num_nodes, k - n_available, device=device
            )
            pe = torch.cat([pe, padding], dim=1)

        # Sign ambiguity: make the largest absolute value in each
        # eigenvector positive for consistency.
        max_idx = pe.abs().argmax(dim=0)
        signs = pe[max_idx, torch.arange(k, device=device)].sign()
        pe = pe * signs.unsqueeze(0)

        return pe

    def forward(
        self, edge_index: torch.Tensor, num_nodes: int, batch: torch.Tensor
    ) -> torch.Tensor:
        """Compute spectral PE for a batched graph.

        Args:
            edge_index: (2, E) edge index tensor.
            num_nodes: total number of nodes across all graphs.
            batch: (N,) graph membership tensor.

        Returns:
            pe: (N, d_model) positional encoding for each node.
        """
        device = edge_index.device
        num_graphs = int(batch.max().item()) + 1 if batch.numel() > 0 else 1

        all_pe = torch.zeros(num_nodes, self.k, device=device)

        for g in range(num_graphs):
            node_mask = batch == g
            node_indices = torch.where(node_mask)[0]
            n_g = node_indices.shape[0]

            if n_g == 0:
                continue

            # Remap edge_index to local indices.
            # Build a mapping from global to local.
            global_to_local = torch.full(
                (num_nodes,), -1, dtype=torch.long, device=device
            )
            global_to_local[node_indices] = torch.arange(
                n_g, dtype=torch.long, device=device
            )

            # Filter edges belonging to this graph.
            src_in_g = node_mask[edge_index[0]]
            dst_in_g = node_mask[edge_index[1]]
            edge_mask = src_in_g & dst_in_g

            if edge_mask.any():
                local_ei = global_to_local[edge_index[:, edge_mask]]
            else:
                local_ei = torch.zeros(
                    2, 0, dtype=torch.long, device=device
                )

            pe_g = self._compute_laplacian_pe(local_ei, n_g, self.k)
            all_pe[node_indices] = pe_g

        return self.linear(all_pe)


# ---------------------------------------------------------------------------
# Edge-Biased Multi-Head Attention
# ---------------------------------------------------------------------------


class EdgeBiasedAttention(nn.Module):
    """Multi-head attention with edge feature bias.

    Standard dot-product attention is augmented with an additive bias
    derived from edge features:

        Attention(Q, K, V) = softmax( (Q K^T / sqrt(d)) + EdgeBias ) V

    where EdgeBias = MLP(edge_features) produces a scalar bias per head
    for each edge in the graph.
    """

    def __init__(
        self,
        d_model: int,
        n_heads: int = 8,
        dropout: float = 0.1,
        edge_feat_dim: int = EDGE_FEAT_DIM,
    ) -> None:
        super().__init__()
        assert d_model % n_heads == 0
        self.d_model = d_model
        self.n_heads = n_heads
        self.d_k = d_model // n_heads

        self.W_q = nn.Linear(d_model, d_model)
        self.W_k = nn.Linear(d_model, d_model)
        self.W_v = nn.Linear(d_model, d_model)
        self.W_o = nn.Linear(d_model, d_model)

        # Edge bias MLP: edge_feat_dim -> n_heads (one scalar per head).
        self.edge_bias_mlp = nn.Sequential(
            nn.Linear(edge_feat_dim, d_model),
            nn.ReLU(inplace=True),
            nn.Linear(d_model, n_heads),
        )

        self.attn_dropout = nn.Dropout(dropout)
        self.scale = math.sqrt(self.d_k)

    def forward(
        self,
        x: torch.Tensor,
        edge_index: torch.Tensor,
        edge_attr: torch.Tensor | None = None,
        batch: torch.Tensor | None = None,
    ) -> torch.Tensor:
        """Forward pass.

        Args:
            x: (N, d_model) node features.
            edge_index: (2, E) edge indices.
            edge_attr: (E, edge_feat_dim) optional edge features.
            batch: (N,) graph membership.

        Returns:
            out: (N, d_model) updated node features.
        """
        N = x.shape[0]
        device = x.device

        Q = self.W_q(x).view(N, self.n_heads, self.d_k)  # (N, H, dk)
        K = self.W_k(x).view(N, self.n_heads, self.d_k)
        V = self.W_v(x).view(N, self.n_heads, self.d_k)

        # Full attention: O(N^2) per graph.  For N < 100 this is fine.
        # Process per-graph to avoid cross-graph attention.
        if batch is None:
            batch = torch.zeros(N, dtype=torch.long, device=device)

        num_graphs = int(batch.max().item()) + 1
        out = torch.zeros_like(x).view(N, self.n_heads, self.d_k)

        for g in range(num_graphs):
            mask = batch == g
            indices = torch.where(mask)[0]
            n_g = indices.shape[0]
            if n_g == 0:
                continue

            Q_g = Q[indices]  # (n_g, H, dk)
            K_g = K[indices]
            V_g = V[indices]

            # Dot-product attention scores: (n_g, H, n_g).
            scores = torch.einsum("ihd,jhd->ijh", Q_g, K_g) / self.scale

            # Add edge bias if edge features are available.
            if edge_attr is not None and edge_index.shape[1] > 0:
                # Build local-index mapping.
                global_to_local = torch.full(
                    (N,), -1, dtype=torch.long, device=device
                )
                global_to_local[indices] = torch.arange(
                    n_g, dtype=torch.long, device=device
                )

                # Filter edges within this graph.
                src_mask = mask[edge_index[0]]
                dst_mask = mask[edge_index[1]]
                edge_mask = src_mask & dst_mask

                if edge_mask.any():
                    local_src = global_to_local[edge_index[0, edge_mask]]
                    local_dst = global_to_local[edge_index[1, edge_mask]]
                    local_edge_attr = edge_attr[edge_mask]

                    # Compute bias: (E_g, H).
                    bias = self.edge_bias_mlp(local_edge_attr)
                    # Scatter into attention scores.
                    scores[local_src, local_dst] += bias

            attn = F.softmax(scores, dim=1)  # softmax over keys (dim=1)
            attn = self.attn_dropout(attn)

            # Weighted sum: (n_g, H, dk).
            out_g = torch.einsum("ijh,jhd->ihd", attn, V_g)
            out[indices] = out_g

        # Reshape and project.
        out = out.reshape(N, self.d_model)
        return self.W_o(out)


# ---------------------------------------------------------------------------
# Graph Transformer Layer
# ---------------------------------------------------------------------------


class GraphTransformerLayer(nn.Module):
    """Single Graph Transformer layer.

    Pre-norm architecture:
        x -> LayerNorm -> EdgeBiasedAttention -> residual -> LayerNorm -> FFN -> residual
    """

    def __init__(
        self,
        d_model: int,
        n_heads: int = 8,
        d_ff: int = 512,
        dropout: float = 0.1,
        edge_feat_dim: int = EDGE_FEAT_DIM,
    ) -> None:
        super().__init__()
        self.norm1 = nn.LayerNorm(d_model)
        self.attn = EdgeBiasedAttention(
            d_model, n_heads, dropout, edge_feat_dim
        )
        self.norm2 = nn.LayerNorm(d_model)
        self.ffn = nn.Sequential(
            nn.Linear(d_model, d_ff),
            nn.GELU(),
            nn.Dropout(dropout),
            nn.Linear(d_ff, d_model),
            nn.Dropout(dropout),
        )

    def forward(
        self,
        x: torch.Tensor,
        edge_index: torch.Tensor,
        edge_attr: torch.Tensor | None = None,
        batch: torch.Tensor | None = None,
    ) -> torch.Tensor:
        """Apply one Graph Transformer layer (pre-norm attention + FFN with residuals).

        Args:
            x: (N, d_model) node features.
            edge_index: (2, E) edge indices.
            edge_attr: (E, edge_feat_dim) optional edge features.
            batch: (N,) graph membership.

        Returns:
            (N, d_model) updated node features.
        """
        # Pre-norm attention + residual.
        h = self.norm1(x)
        h = self.attn(h, edge_index, edge_attr, batch)
        x = x + h
        # Pre-norm FFN + residual.
        h = self.norm2(x)
        h = self.ffn(h)
        x = x + h
        return x


# ---------------------------------------------------------------------------
# Graph Transformer Actor-Critic
# ---------------------------------------------------------------------------


class GraphTransformerActorCritic(nn.Module):
    """Graph Transformer policy for sequential device placement.

    Architecture (~2.5M params):
        NodeProjection(16 -> d_model) + SpectralPE(k=8, d_model)
        -> 6x GraphTransformerLayer(d_model, 8 heads, d_ff=512)
        -> concat(global_mean_pool, device_embedding)
        -> Actor:  MLP(2*d_model -> d_model -> num_actions)
        -> Critic: MLP(d_model -> d_model -> 1)
    """

    def __init__(
        self,
        node_feat_dim: int = NODE_FEAT_DIM,
        d_model: int = 192,
        n_layers: int = 6,
        n_heads: int = 8,
        d_ff: int = 512,
        num_actions: int = NUM_ACTIONS,
        spectral_k: int = SPECTRAL_PE_DIM,
        edge_feat_dim: int = EDGE_FEAT_DIM,
        dropout: float = 0.1,
    ) -> None:
        super().__init__()
        self.d_model = d_model
        self.use_edge_features = edge_feat_dim > 0

        # Input projection.
        self.node_proj = nn.Sequential(
            nn.Linear(node_feat_dim, d_model),
            nn.LayerNorm(d_model),
        )

        # Spectral positional encoding.
        self.spectral_pe = SpectralPositionalEncoding(k=spectral_k, d_model=d_model)

        # Transformer layers.
        self.layers = nn.ModuleList([
            GraphTransformerLayer(
                d_model=d_model,
                n_heads=n_heads,
                d_ff=d_ff,
                dropout=dropout,
                edge_feat_dim=edge_feat_dim,
            )
            for _ in range(n_layers)
        ])

        self.final_norm = nn.LayerNorm(d_model)

        # Actor head: global embedding + device embedding -> action logits.
        self.actor = nn.Sequential(
            nn.Linear(d_model * 2, d_model),
            nn.GELU(),
            nn.Dropout(dropout),
            nn.Linear(d_model, d_model // 2),
            nn.GELU(),
            nn.Linear(d_model // 2, num_actions),
        )

        # Critic head: global embedding -> scalar value.
        self.critic = nn.Sequential(
            nn.Linear(d_model, d_model),
            nn.GELU(),
            nn.Dropout(dropout),
            nn.Linear(d_model, d_model // 2),
            nn.GELU(),
            nn.Linear(d_model // 2, 1),
        )

        self._init_weights()

    def _init_weights(self) -> None:
        """Initialise linear layers with Kaiming normal and layer norms to identity."""
        for m in self.modules():
            if isinstance(m, nn.Linear):
                nn.init.kaiming_normal_(m.weight, nonlinearity="relu")
                if m.bias is not None:
                    nn.init.zeros_(m.bias)
            elif isinstance(m, nn.LayerNorm):
                nn.init.ones_(m.weight)
                nn.init.zeros_(m.bias)

    def forward(
        self,
        x: torch.Tensor,
        edge_index: torch.Tensor,
        batch: torch.Tensor,
        current_device_idx: torch.Tensor,
        edge_attr: torch.Tensor | None = None,
    ) -> tuple[torch.Tensor, torch.Tensor]:
        """Forward pass.

        Args:
            x: (N_total, node_feat_dim) node features.
            edge_index: (2, E_total) edge indices.
            batch: (N_total,) graph membership.
            current_device_idx: (B,) index of device being placed.
            edge_attr: (E, edge_feat_dim) optional edge features.

        Returns:
            action_logits: (B, num_actions).
            values: (B, 1).
        """
        N = x.shape[0]

        # Project node features.
        h = self.node_proj(x)

        # Add spectral positional encoding.
        pe = self.spectral_pe(edge_index, N, batch)
        h = h + pe

        # Transformer layers.
        for layer in self.layers:
            h = layer(h, edge_index, edge_attr, batch)

        h = self.final_norm(h)

        # Global graph embedding via mean pooling.
        num_graphs = int(batch.max().item()) + 1 if batch.numel() > 0 else 1
        graph_emb = torch.zeros(
            num_graphs, self.d_model, device=h.device, dtype=h.dtype
        )
        for g in range(num_graphs):
            mask = batch == g
            if mask.any():
                graph_emb[g] = h[mask].mean(dim=0)

        # Current device embedding.
        device_emb = h[current_device_idx]  # (B, d_model)

        # Actor: concat global + device -> logits.
        actor_input = torch.cat([graph_emb, device_emb], dim=-1)
        action_logits = self.actor(actor_input)

        # Critic: global embedding -> value.
        values = self.critic(graph_emb)

        return action_logits, values

    def get_action_and_value(
        self,
        x: torch.Tensor,
        edge_index: torch.Tensor,
        batch: torch.Tensor,
        current_device_idx: torch.Tensor,
        action: torch.Tensor | None = None,
        edge_attr: torch.Tensor | None = None,
    ) -> tuple[torch.Tensor, torch.Tensor, torch.Tensor, torch.Tensor]:
        """Sample (or evaluate) an action and return PPO quantities.

        Args:
            x, edge_index, batch, current_device_idx: same as forward().
            action: if provided, evaluate this action instead of sampling.
            edge_attr: optional edge features.

        Returns:
            action, log_prob, entropy, value
        """
        logits, values = self.forward(
            x, edge_index, batch, current_device_idx, edge_attr
        )
        dist = torch.distributions.Categorical(logits=logits)

        if action is None:
            action = dist.sample()

        log_prob = dist.log_prob(action)
        entropy = dist.entropy()

        return action, log_prob, entropy, values.squeeze(-1)

    def predict_initial_placement(
        self,
        x: torch.Tensor,
        edge_index: torch.Tensor,
        batch: torch.Tensor,
        edge_attr: torch.Tensor | None = None,
        grid_size: int = GRID_SIZE,
    ) -> torch.Tensor:
        """Predict initial placement for all devices in one pass (greedy).

        Used in hybrid mode: Transformer produces a seed placement, then
        SA refines.

        Args:
            x: (N, node_feat_dim) node features.
            edge_index: (2, E) edges.
            batch: (N,) graph membership.
            edge_attr: optional edge features.
            grid_size: grid resolution.

        Returns:
            positions: (N, 2) float32 positions in [0, grid_size].
        """
        N = x.shape[0]
        device = x.device
        positions = torch.zeros(N, 2, device=device)

        # Process each device sequentially (greedy rollout).
        for i in range(N):
            cidx = torch.tensor([i], device=device)
            logits, _ = self.forward(x, edge_index, batch, cidx, edge_attr)

            # Greedy: take argmax.
            action = logits.argmax(dim=-1).item()
            row = action // grid_size
            col = action % grid_size
            positions[i, 0] = float(col)
            positions[i, 1] = float(row)

            # Update the placement state in x (columns: placed, grid_x, grid_y).
            # Indices into the state portion of node features.
            x[i, DEVICE_FEAT_DIM] = 1.0  # placed flag
            x[i, DEVICE_FEAT_DIM + 1] = col / grid_size
            x[i, DEVICE_FEAT_DIM + 2] = row / grid_size
            x[i, DEVICE_FEAT_DIM + 3] = (i + 1) / N

        return positions


# ---------------------------------------------------------------------------
# Edge feature computation
# ---------------------------------------------------------------------------


def compute_edge_features(
    edge_index: torch.Tensor,
    positions: torch.Tensor | None = None,
    n_nodes: int = 0,
) -> torch.Tensor:
    """Compute edge features from circuit graph structure.

    Args:
        edge_index: (2, E) edge indices.
        positions: (N, 2) optional current positions.
        n_nodes: number of nodes (for degree computation).

    Returns:
        edge_attr: (E, EDGE_FEAT_DIM) edge features.
    """
    E = edge_index.shape[1]
    device = edge_index.device

    if E == 0:
        return torch.zeros(0, EDGE_FEAT_DIM, device=device)

    feats = torch.zeros(E, EDGE_FEAT_DIM, device=device)

    src, dst = edge_index[0], edge_index[1]

    # Feature 0: Euclidean distance between connected nodes (if positions given).
    if positions is not None and positions.shape[0] > 0:
        dx = positions[src, 0] - positions[dst, 0]
        dy = positions[src, 1] - positions[dst, 1]
        dist = torch.sqrt(dx * dx + dy * dy + 1e-8)
        # Normalise by max distance.
        max_dist = dist.max()
        if max_dist > 0:
            feats[:, 0] = dist / max_dist
    else:
        feats[:, 0] = 1.0

    # Feature 1: inverse edge multiplicity (shared nets proxy).
    # Count how many edges connect each (src, dst) pair.
    if E > 0 and n_nodes > 0:
        pair_ids = src * n_nodes + dst
        unique_pairs, inverse, counts = torch.unique(
            pair_ids, return_inverse=True, return_counts=True
        )
        feats[:, 1] = 1.0 / counts[inverse].float()

    # Feature 2: source degree (normalised).
    if n_nodes > 0:
        deg = torch.zeros(n_nodes, device=device)
        deg.scatter_add_(0, src, torch.ones(E, device=device))
        max_deg = deg.max()
        if max_deg > 0:
            feats[:, 2] = deg[src] / max_deg

    # Feature 3: destination degree (normalised).
    if n_nodes > 0:
        deg = torch.zeros(n_nodes, device=device)
        deg.scatter_add_(0, dst, torch.ones(E, device=device))
        max_deg = deg.max()
        if max_deg > 0:
            feats[:, 3] = deg[dst] / max_deg

    return feats


# ---------------------------------------------------------------------------
# Convenience
# ---------------------------------------------------------------------------


def build_transformer_model(
    device: torch.device | str = "cpu",
    **kwargs,
) -> GraphTransformerActorCritic:
    """Create a GraphTransformerActorCritic and move it to the specified device.

    Args:
        device: Target device (e.g. "cpu", "cuda").
        **kwargs: Forwarded to GraphTransformerActorCritic.__init__.

    Returns:
        Initialised model on the requested device.
    """
    model = GraphTransformerActorCritic(**kwargs)
    return model.to(device)


if __name__ == "__main__":
    model = build_transformer_model()
    print(model)

    # Smoke test with a single graph.
    n_nodes, n_edges = 20, 60
    x = torch.randn(n_nodes, NODE_FEAT_DIM)
    edge_index = torch.randint(0, n_nodes, (2, n_edges))
    batch = torch.zeros(n_nodes, dtype=torch.long)
    current_idx = torch.tensor([0])

    edge_attr = compute_edge_features(edge_index, n_nodes=n_nodes)

    action_logits, values = model(
        x, edge_index, batch, current_idx, edge_attr=edge_attr
    )
    print(f"Node features:    {x.shape}")
    print(f"Action logits:    {action_logits.shape}")
    print(f"Values:           {values.shape}")

    action, log_prob, entropy, value = model.get_action_and_value(
        x, edge_index, batch, current_idx, edge_attr=edge_attr,
    )
    print(f"Sampled action:   {action.item()}")
    print(f"Log prob:         {log_prob.item():.4f}")
    print(f"Entropy:          {entropy.item():.4f}")

    total_params = sum(p.numel() for p in model.parameters())
    print(f"Total parameters: {total_params:,}")

    # Test hybrid placement.
    x2 = torch.randn(n_nodes, NODE_FEAT_DIM)
    positions = model.predict_initial_placement(
        x2, edge_index, batch, edge_attr=edge_attr
    )
    print(f"Predicted positions: {positions.shape}")
