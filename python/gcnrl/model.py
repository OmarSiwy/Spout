"""GCN-RL placement models for sequential device placement.

Essential model steps:
    1. Encode the circuit graph and placement state into node embeddings.
    2. Pool graph context and gather the active device embedding.
    3. Decode actor logits for grid positions and a critic value for PPO.

Optimization rationale:
    - Actor and critic use separate backbones to reduce gradient interference.
    - The actor head uses a small final-layer initialization so PPO starts from
      a conservative policy instead of saturating on the first updates.
    - Reusable transformer machinery lives in ``python_refactor.utility`` so
      the shared attention logic stays generic while ``model.py`` remains the
      public home for placement models.
"""

from __future__ import annotations

import torch
import torch.nn as nn
import torch.nn.functional as F
from torch_geometric.nn import GATv2Conv, global_mean_pool

from ..utility.graph_transformer import (
    GraphTransformerActorCritic,
    build_transformer_model,
    compute_edge_features,
)


# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

DEVICE_FEAT_DIM = 12   # type one-hot(6) + W, L, fingers, mult, x, y
STATE_FEAT_DIM = 4     # placed flag, grid_x, grid_y, step_fraction
NODE_FEAT_DIM = DEVICE_FEAT_DIM + STATE_FEAT_DIM  # 16
GRID_SIZE = 16         # 16 x 16 placement grid
NUM_ACTIONS = GRID_SIZE * GRID_SIZE  # 256 possible positions


# ---------------------------------------------------------------------------
# GATv2 Backbone (shared architecture, separate instances)
# ---------------------------------------------------------------------------


class GATv2Backbone(nn.Module):
    """3-layer GATv2 backbone for extracting per-node graph embeddings."""

    def __init__(
        self,
        node_feat_dim: int,
        hidden_dim: int,
        dropout: float,
    ) -> None:
        super().__init__()
        self.conv1 = GATv2Conv(node_feat_dim, hidden_dim // 4, heads=4, concat=True, add_self_loops=True)
        self.ln1 = nn.LayerNorm(hidden_dim)
        self.conv2 = GATv2Conv(hidden_dim, hidden_dim // 4, heads=4, concat=True, add_self_loops=True)
        self.ln2 = nn.LayerNorm(hidden_dim)
        self.conv3 = GATv2Conv(hidden_dim, hidden_dim, heads=1, concat=False, add_self_loops=True)
        self.ln3 = nn.LayerNorm(hidden_dim)
        self.dropout = nn.Dropout(p=dropout)

    def forward(self, x: torch.Tensor, edge_index: torch.Tensor) -> torch.Tensor:
        # Step 1: aggregate local graph context.
        h = self.conv1(x, edge_index)
        h = self.ln1(h)
        h = F.relu(h, inplace=True)
        h = self.dropout(h)

        # Step 2: refine the node state with deeper neighborhood context.
        h = self.conv2(h, edge_index)
        h = self.ln2(h)
        h = F.relu(h, inplace=True)
        h = self.dropout(h)

        # Step 3: project each node into the policy/value embedding space.
        h = self.conv3(h, edge_index)
        h = self.ln3(h)
        h = F.relu(h, inplace=True)
        return h


# ---------------------------------------------------------------------------
# Actor-Critic Model
# ---------------------------------------------------------------------------


class GCNActorCritic(nn.Module):
    """Actor-critic GATv2 policy for sequential placement.

    Essential model steps:
        1. Build actor and critic node embeddings from the same circuit state.
        2. Form the actor state from graph context plus the device being placed.
        3. Decode action logits and a scalar value estimate.

    Optimization rationale:
        Separate backbones keep policy and value gradients from distorting the
        same latent space, which improves PPO stability on placement tasks.
    """

    def __init__(
        self,
        node_feat_dim: int = NODE_FEAT_DIM,
        hidden_dim: int = 128,
        num_actions: int = NUM_ACTIONS,
        dropout: float = 0.1,
    ) -> None:
        super().__init__()
        self.hidden_dim = hidden_dim

        # Optimization rationale: separate backbones reduce actor/critic
        # interference during PPO updates.
        self.actor_backbone = GATv2Backbone(node_feat_dim, hidden_dim, dropout)
        self.critic_backbone = GATv2Backbone(node_feat_dim, hidden_dim, dropout)

        # Actor head: global embedding + current device embedding -> action logits.
        self.actor = nn.Sequential(
            nn.Linear(hidden_dim * 2, hidden_dim),
            nn.ReLU(inplace=True),
            nn.Linear(hidden_dim, num_actions),
        )

        # Critic head: global embedding -> scalar value.
        self.critic = nn.Sequential(
            nn.Linear(hidden_dim, hidden_dim),
            nn.ReLU(inplace=True),
            nn.Linear(hidden_dim, 1),
        )

        self._init_weights()

    def _init_weights(self) -> None:
        """Initialise linear layers with Kaiming normal and layer norms to identity.

        Policy head final layer gets 0.01x scaling for conservative initial policy
        (ICLR 2021 recommendation).
        """
        for m in self.modules():
            if isinstance(m, nn.Linear):
                nn.init.kaiming_normal_(m.weight, nonlinearity="relu")
                if m.bias is not None:
                    nn.init.zeros_(m.bias)
            elif isinstance(m, nn.LayerNorm):
                nn.init.ones_(m.weight)
                nn.init.zeros_(m.bias)

        # Optimization rationale: conservative initial logits reduce destructive
        # early policy updates before the critic is calibrated.
        with torch.no_grad():
            self.actor[-1].weight.mul_(0.01)

    def forward(
        self,
        x: torch.Tensor,
        edge_index: torch.Tensor,
        batch: torch.Tensor,
        current_device_idx: torch.Tensor,
    ) -> tuple[torch.Tensor, torch.Tensor]:
        """Forward pass through separate actor and critic backbones.

        Args:
            x: (N_total, 16) node features for all graphs in the batch.
            edge_index: (2, E_total) batched edge indices.
            batch: (N_total,) graph membership for each node.
            current_device_idx: (B,) index of the device being placed in each
                graph (relative to the start of each graph in the batch).

        Returns:
            action_logits: (B, num_actions) unnormalised log-probs over grid.
            values: (B, 1) state value estimates.
        """
        # Step 1: encode the graph for the actor pathway.
        h_actor = self.actor_backbone(x, edge_index)
        actor_graph_emb = global_mean_pool(h_actor, batch)
        device_emb = h_actor[current_device_idx]  # (B, hidden)

        # Step 2: combine global context with the device being placed.
        actor_input = torch.cat([actor_graph_emb, device_emb], dim=-1)  # (B, 2*hidden)
        action_logits = self.actor(actor_input)  # (B, num_actions)

        # Step 3: score the same state with the critic pathway.
        h_critic = self.critic_backbone(x, edge_index)
        # Step 4: pool graph context and predict the value baseline.
        critic_graph_emb = global_mean_pool(h_critic, batch)
        values = self.critic(critic_graph_emb)  # (B, 1)

        return action_logits, values

    def get_action_and_value(
        self,
        x: torch.Tensor,
        edge_index: torch.Tensor,
        batch: torch.Tensor,
        current_device_idx: torch.Tensor,
        action: torch.Tensor | None = None,
        action_mask: torch.Tensor | None = None,
    ) -> tuple[torch.Tensor, torch.Tensor, torch.Tensor, torch.Tensor]:
        """Sample (or evaluate) an action and return policy quantities for PPO.

        Args:
            x, edge_index, batch, current_device_idx: same as forward().
            action: if provided, evaluate this action instead of sampling.
            action_mask: (B, num_actions) bool tensor; False = illegal position.

        Returns:
            action: (B,) sampled or provided action.
            log_prob: (B,) log-probability of the action.
            entropy: (B,) entropy of the action distribution.
            value: (B,) state value estimate.
        """
        logits, values = self.forward(x, edge_index, batch, current_device_idx)
        if action_mask is not None:
            # Use -1e4 instead of -1e8 to stay within float16 range for AMP.
            logits = logits.masked_fill(~action_mask, -1e4)
        dist = torch.distributions.Categorical(logits=logits)

        if action is None:
            action = dist.sample()

        log_prob = dist.log_prob(action)
        entropy = dist.entropy()

        return action, log_prob, entropy, values.squeeze(-1)


# ---------------------------------------------------------------------------
# Convenience helpers
# ---------------------------------------------------------------------------


def build_model(
    device: torch.device | str = "cpu",
    **kwargs,
) -> GCNActorCritic:
    """Convenience factory that creates and moves the model."""
    model = GCNActorCritic(**kwargs)
    return model.to(device)


if __name__ == "__main__":
    model = build_model()
    print(model)

    # Smoke test with a single graph.
    n_nodes, n_edges = 20, 60
    x = torch.randn(n_nodes, NODE_FEAT_DIM)
    edge_index = torch.randint(0, n_nodes, (2, n_edges))
    batch = torch.zeros(n_nodes, dtype=torch.long)
    current_idx = torch.tensor([0])

    action_logits, values = model(x, edge_index, batch, current_idx)
    print(f"Node features:  {x.shape}")
    print(f"Action logits:  {action_logits.shape}")
    print(f"Values:         {values.shape}")

    action, log_prob, entropy, value = model.get_action_and_value(
        x, edge_index, batch, current_idx,
    )
    print(f"Sampled action: {action.item()}")
    print(f"Log prob:       {log_prob.item():.4f}")
    print(f"Entropy:        {entropy.item():.4f}")

    total_params = sum(p.numel() for p in model.parameters())
    print(f"Total parameters: {total_params:,}")


__all__ = [
    "DEVICE_FEAT_DIM",
    "STATE_FEAT_DIM",
    "NODE_FEAT_DIM",
    "GRID_SIZE",
    "NUM_ACTIONS",
    "GATv2Backbone",
    "GCNActorCritic",
    "GraphTransformerActorCritic",
    "build_model",
    "build_transformer_model",
    "compute_edge_features",
]
