"""Surrogate cost MLP for fast placement-cost prediction.

Essential model steps:
    1. Encode the placement feature vector through residual SELU blocks.
    2. Branch into one lightweight head per predicted metric.
    3. Concatenate the metric predictions into a single output tensor.

Optimization rationale:
    - SELU + AlphaDropout keep activations stable without extra normalization.
    - Residual projections preserve signal quality across width changes.
"""

from __future__ import annotations

import torch
import torch.nn as nn


class ResidualBlock(nn.Module):
    """SELU linear block with projection residual."""

    def __init__(self, in_dim: int, out_dim: int, dropout: float = 0.1) -> None:
        super().__init__()
        self.linear = nn.Linear(in_dim, out_dim)
        self.act = nn.SELU(inplace=True)
        self.drop = nn.AlphaDropout(p=dropout)
        self.proj = nn.Linear(in_dim, out_dim, bias=False) if in_dim != out_dim else nn.Identity()

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        # Step 1: transform the feature stream.
        hidden = self.drop(self.act(self.linear(x)))
        # Step 2: preserve the input path for stable residual learning.
        return hidden + self.proj(x)


class SurrogateCostMLP(nn.Module):
    """Multi-head MLP for surrogate cost estimation.

    Essential model steps:
        1. Build a shared latent representation from the 69-D feature vector.
        2. Decode each cost metric with its own shallow prediction head.
        3. Concatenate the per-metric outputs for downstream training/inference.
    """

    def __init__(
        self,
        in_features: int = 69,
        out_features: int = 4,
        hidden_dims: tuple[int, ...] = (512, 256, 128, 64),
        dropout: float = 0.1,
    ) -> None:
        super().__init__()
        self.in_features = in_features
        self.out_features = out_features

        blocks: list[nn.Module] = []
        prev_dim = in_features
        for h_dim in hidden_dims:
            blocks.append(ResidualBlock(prev_dim, h_dim, dropout))
            prev_dim = h_dim
        self.backbone = nn.Sequential(*blocks)

        # Per-output task-specific heads (2-layer with SELU + AlphaDropout).
        self.heads = nn.ModuleList([
            nn.Sequential(
                nn.Linear(prev_dim, 32),
                nn.SELU(),
                nn.AlphaDropout(p=dropout * 0.5),
                nn.Linear(32, 1),
            )
            for _ in range(out_features)
        ])

        self._init_weights()

    def _init_weights(self) -> None:
        """Initialise with lecun_normal for SELU layers."""
        for m in self.modules():
            if isinstance(m, nn.Linear):
                nn.init.kaiming_normal_(m.weight, mode="fan_in", nonlinearity="linear")
                if m.bias is not None:
                    nn.init.zeros_(m.bias)

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        """Forward pass.

        Args:
            x: Tensor of shape (batch, 69).

        Returns:
            Tensor of shape (batch, 4) — [wirelength, vias, resistance, capacitance].
        """
        # Step 1: encode the placement features once in a shared backbone.
        h = self.backbone(x)
        # Step 2: decode each target with its dedicated head.
        outputs = [head(h) for head in self.heads]
        # Step 3: pack the per-target outputs into one tensor.
        return torch.cat(outputs, dim=-1)


def build_model(
    device: torch.device | str = "cpu",
    **kwargs,
) -> SurrogateCostMLP:
    """Create a SurrogateCostMLP and move it to the specified device."""
    model = SurrogateCostMLP(**kwargs)
    return model.to(device)


class SurrogateEnsemble(nn.Module):
    """Deep ensemble of independently trained surrogate models.

    Optimization rationale:
        Averaging multiple independently trained members improves robustness
        and gives a practical uncertainty estimate without changing the base
        model architecture.
    """

    def __init__(self, n_members: int = 5, **kwargs) -> None:
        super().__init__()
        self.members = nn.ModuleList([
            SurrogateCostMLP(**kwargs) for _ in range(n_members)
        ])

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        """Average prediction across ensemble members.

        Returns:
            Tensor of shape (batch, 4) — averaged predictions.
        """
        preds = torch.stack([m(x) for m in self.members], dim=0)  # (N, batch, 4)
        return preds.mean(dim=0)

    def predict_with_uncertainty(self, x: torch.Tensor) -> tuple[torch.Tensor, torch.Tensor]:
        """Return mean prediction and per-output standard deviation.

        Returns:
            (mean, std): mean is (batch, 4), std is (batch, 4).
        """
        preds = torch.stack([m(x) for m in self.members], dim=0)
        return preds.mean(dim=0), preds.std(dim=0)


def build_ensemble(
    n_members: int = 5,
    device: torch.device | str = "cpu",
    **kwargs,
) -> SurrogateEnsemble:
    """Create a SurrogateEnsemble and move it to the specified device."""
    model = SurrogateEnsemble(n_members=n_members, **kwargs)
    return model.to(device)


if __name__ == "__main__":
    model = build_model()
    print(model)
    x = torch.randn(8, 69)
    y = model(x)
    print(f"Input shape:  {x.shape}")
    print(f"Output shape: {y.shape}")
    total_params = sum(p.numel() for p in model.parameters())
    print(f"Total parameters: {total_params:,}")
