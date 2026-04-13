"""UNet-style repair model for DRC-violation heatmaps.

Essential model steps:
    1. Encode the rasterized layout into a hierarchy of spatial features.
    2. Optionally inject graph-level conditioning at the bottleneck.
    3. Decode back to image space with attention-gated skip connections.
    4. Produce raw violation logits with a final 1x1 prediction head.

Optimization rationale:
    - Attention gates focus skip traffic on violation-relevant regions.
    - FiLM conditioning adds circuit context without changing the image path.
    - Gradient checkpointing is optional because it is a memory optimization,
      not a separate model step.
"""

from __future__ import annotations

import math

import torch
import torch.nn as nn
from torch.utils.checkpoint import checkpoint as grad_checkpoint


# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

IN_CHANNELS = 5
OUT_CHANNELS = 1
IMG_SIZE = 512


# ---------------------------------------------------------------------------
# Building blocks
# ---------------------------------------------------------------------------


class ResConvBlock(nn.Module):
    """Two consecutive Conv-BN-ReLU layers with a residual skip connection."""

    def __init__(self, in_ch: int, out_ch: int) -> None:
        super().__init__()
        self.block = nn.Sequential(
            nn.Conv2d(in_ch, out_ch, 3, padding=1, bias=False),
            nn.BatchNorm2d(out_ch),
            nn.ReLU(inplace=True),
            nn.Conv2d(out_ch, out_ch, 3, padding=1, bias=False),
            nn.BatchNorm2d(out_ch),
        )
        self.proj = nn.Conv2d(in_ch, out_ch, 1, bias=False) if in_ch != out_ch else nn.Identity()
        self.relu = nn.ReLU(inplace=True)

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        return self.relu(self.block(x) + self.proj(x))


# Backward compatibility alias.
ConvBlock = ResConvBlock


class EncoderBlock(nn.Module):
    """ConvBlock followed by MaxPool for downsampling."""

    def __init__(self, in_ch: int, out_ch: int) -> None:
        super().__init__()
        self.conv = ConvBlock(in_ch, out_ch)
        self.pool = nn.MaxPool2d(kernel_size=2, stride=2)

    def forward(self, x: torch.Tensor) -> tuple[torch.Tensor, torch.Tensor]:
        """Returns (pooled, skip) where skip is the pre-pool feature map."""
        skip = self.conv(x)
        pooled = self.pool(skip)
        return pooled, skip


class AttentionGate(nn.Module):
    """Attention gate for skip connections.

    Suppresses irrelevant spatial regions in the encoder feature map by
    learning a gating signal from the decoder.  Follows Oktay et al.,
    "Attention U-Net" (MIDL 2018).

    Args:
        F_g: Number of channels in the gating signal (from decoder).
        F_l: Number of channels in the skip connection (from encoder).
        F_int: Number of intermediate channels for the attention map.
    """

    def __init__(self, F_g: int, F_l: int, F_int: int) -> None:
        super().__init__()
        self.W_g = nn.Sequential(
            nn.Conv2d(F_g, F_int, kernel_size=1, bias=False),
            nn.BatchNorm2d(F_int),
        )
        self.W_x = nn.Sequential(
            nn.Conv2d(F_l, F_int, kernel_size=1, bias=False),
            nn.BatchNorm2d(F_int),
        )
        self.psi = nn.Sequential(
            nn.Conv2d(F_int, 1, kernel_size=1, bias=True),
            nn.Sigmoid(),
        )
        self.relu = nn.ReLU(inplace=True)

    def forward(self, g: torch.Tensor, x: torch.Tensor) -> torch.Tensor:
        """Apply attention gating.

        Args:
            g: (B, F_g, H, W) gating signal from the decoder (upsampled).
            x: (B, F_l, H, W) skip-connection features from the encoder.

        Returns:
            (B, F_l, H, W) attention-weighted encoder features.
        """
        g1 = self.W_g(g)
        x1 = self.W_x(x)
        # Handle potential spatial size mismatch after upsampling.
        if g1.shape[2:] != x1.shape[2:]:
            g1 = nn.functional.interpolate(
                g1, size=x1.shape[2:], mode="bilinear", align_corners=False
            )
        psi = self.relu(g1 + x1)
        psi = self.psi(psi)
        return x * psi


class DecoderBlock(nn.Module):
    """ConvTranspose upsample + attention-gated skip concat + ConvBlock."""

    def __init__(self, in_ch: int, skip_ch: int, out_ch: int) -> None:
        super().__init__()
        self.up = nn.ConvTranspose2d(in_ch, out_ch, kernel_size=2, stride=2)
        self.attn = AttentionGate(F_g=out_ch, F_l=skip_ch, F_int=skip_ch // 2)
        self.conv = ConvBlock(out_ch + skip_ch, out_ch)

    def forward(self, x: torch.Tensor, skip: torch.Tensor) -> torch.Tensor:
        """Upsample x, apply attention gate to skip, concatenate, ConvBlock.

        Args:
            x: (B, in_ch, H, W) decoder feature map to upsample.
            skip: (B, skip_ch, 2H, 2W) encoder skip-connection feature map.

        Returns:
            (B, out_ch, 2H, 2W) merged feature map.
        """
        x = self.up(x)
        # Handle potential size mismatches from odd input dimensions.
        if x.shape[2:] != skip.shape[2:]:
            x = nn.functional.interpolate(
                x, size=skip.shape[2:], mode="bilinear", align_corners=False
            )
        skip = self.attn(g=x, x=skip)
        x = torch.cat([x, skip], dim=1)
        return self.conv(x)


# ---------------------------------------------------------------------------
# FiLM conditioning (Feature-wise Linear Modulation)
# ---------------------------------------------------------------------------


class FiLMLayer(nn.Module):
    """Feature-wise Linear Modulation -- injects graph context into CNN features.

    Given a conditioning vector ``cond`` (e.g. a graph-level embedding), the
    layer learns per-channel affine parameters ``gamma`` and ``beta`` and
    applies ``output = gamma * features + beta``.

    Args:
        n_channels: Number of feature-map channels to modulate.
        cond_dim:   Dimensionality of the conditioning vector.
    """

    def __init__(self, n_channels: int, cond_dim: int) -> None:
        super().__init__()
        self.gamma = nn.Linear(cond_dim, n_channels)
        self.beta = nn.Linear(cond_dim, n_channels)
        # Initialise so that the default modulation is close to identity
        # (gamma ~ 1, beta ~ 0) to avoid disrupting pre-trained weights.
        nn.init.ones_(self.gamma.weight.data[:, 0])
        nn.init.zeros_(self.gamma.bias.data)
        nn.init.zeros_(self.beta.weight.data)
        nn.init.zeros_(self.beta.bias.data)

    def forward(self, x: torch.Tensor, cond: torch.Tensor) -> torch.Tensor:
        """Apply feature-wise affine modulation.

        Args:
            x:    (B, C, H, W) feature map from the bottleneck.
            cond: (B, cond_dim) conditioning vector.

        Returns:
            (B, C, H, W) modulated feature map.
        """
        gamma = self.gamma(cond).unsqueeze(-1).unsqueeze(-1)  # (B, C, 1, 1)
        beta = self.beta(cond).unsqueeze(-1).unsqueeze(-1)    # (B, C, 1, 1)
        return gamma * x + beta


class GraphConditioner(nn.Module):
    """Simple GNN that produces a graph-level embedding for FiLM conditioning.

    Accepts batched node features and mean-pools over the node dimension to
    produce a fixed-size graph embedding.  When node features are already
    graph-level (2-D), the pooling step is skipped.

    Args:
        node_dim: Per-node feature dimensionality.
        hidden:   Hidden layer width.
        out_dim:  Output embedding dimensionality (fed into FiLMLayer).
    """

    def __init__(self, node_dim: int = 12, hidden: int = 64, out_dim: int = 64) -> None:
        super().__init__()
        self.lin1 = nn.Linear(node_dim, hidden)
        self.lin2 = nn.Linear(hidden, out_dim)
        self.act = nn.ReLU()

    def forward(self, node_features: torch.Tensor) -> torch.Tensor:
        """Encode node features into a graph-level embedding.

        Args:
            node_features: (B, max_nodes, node_dim) batched node features, or
                           (B, node_dim) pre-pooled graph-level features.

        Returns:
            (B, out_dim) graph embedding vector.
        """
        if node_features.dim() == 3:
            # Per-node features -- mean-pool over the node dimension.
            x = self.act(self.lin1(node_features))
            x = self.lin2(x)
            return x.mean(dim=1)  # (B, out_dim)
        else:
            x = self.act(self.lin1(node_features))
            return self.lin2(x)


# ---------------------------------------------------------------------------
# UNet
# ---------------------------------------------------------------------------


class UNetRepair(nn.Module):
    """UNet encoder-decoder for DRC violation heatmap prediction.

    Architecture:
        Encoder:    5 -> 64 -> 128 -> 256 -> 512 (with MaxPool between stages)
        Bottleneck: 512 -> 1024 (+ optional FiLM conditioning)
        Decoder:    1024 -> 512 -> 256 -> 128 -> 64 (with attention gates)
        Head:       64 -> 1 (1x1 conv, raw logits)

    When ``use_film=True``, a :class:`FiLMLayer` is inserted after the
    bottleneck convolution.  The layer is only applied when a ``graph_cond``
    tensor is passed to :meth:`forward`; otherwise the model behaves as a
    standard UNet (backward compatible).

    The model outputs raw logits. Apply ``torch.sigmoid`` at inference time
    to obtain violation probabilities in [0, 1].
    """

    def __init__(
        self,
        in_channels: int = IN_CHANNELS,
        out_channels: int = OUT_CHANNELS,
        base_features: int = 64,
        use_checkpointing: bool = False,
        use_film: bool = False,
        film_cond_dim: int = 64,
    ) -> None:
        super().__init__()
        self.use_checkpointing = use_checkpointing
        self.use_film = use_film
        f = base_features

        # Encoder path.
        self.enc1 = EncoderBlock(in_channels, f)       # 512 -> 256
        self.enc2 = EncoderBlock(f, f * 2)              # 256 -> 128
        self.enc3 = EncoderBlock(f * 2, f * 4)          # 128 -> 64
        self.enc4 = EncoderBlock(f * 4, f * 8)          # 64  -> 32

        # Bottleneck.
        self.bottleneck = ConvBlock(f * 8, f * 16)      # 32 x 32

        # Optional FiLM conditioning at the bottleneck.
        self.film: FiLMLayer | None = None
        if use_film:
            self.film = FiLMLayer(n_channels=f * 16, cond_dim=film_cond_dim)

        # Decoder path (with attention-gated skip connections).
        self.dec4 = DecoderBlock(f * 16, f * 8, f * 8)  # 32  -> 64
        self.dec3 = DecoderBlock(f * 8, f * 4, f * 4)   # 64  -> 128
        self.dec2 = DecoderBlock(f * 4, f * 2, f * 2)   # 128 -> 256
        self.dec1 = DecoderBlock(f * 2, f, f)            # 256 -> 512

        # Output head: 1-channel logits (no activation — sigmoid in loss/inference).
        self.head = nn.Conv2d(f, out_channels, kernel_size=1)

        self._init_weights()

    def _init_weights(self) -> None:
        """Initialise conv layers with Kaiming normal and batch norms to identity."""
        for m in self.modules():
            if isinstance(m, (nn.Conv2d, nn.ConvTranspose2d)):
                nn.init.kaiming_normal_(m.weight, nonlinearity="relu")
                if m.bias is not None:
                    nn.init.zeros_(m.bias)
            elif isinstance(m, nn.BatchNorm2d):
                nn.init.ones_(m.weight)
                nn.init.zeros_(m.bias)
        # Optimization rationale: bias the output head toward the dominant
        # "no violation" prior so early training is numerically stable.
        if hasattr(self, 'head') and self.head.bias is not None:
            nn.init.constant_(self.head.bias, math.log(0.05 / 0.95))

    def forward(
        self,
        x: torch.Tensor,
        graph_cond: torch.Tensor | None = None,
    ) -> torch.Tensor:
        """Forward pass.

        Args:
            x: (B, 5, H, W) input layout image.
            graph_cond: Optional (B, cond_dim) graph conditioning vector.
                When provided *and* the model was built with ``use_film=True``,
                FiLM modulation is applied at the bottleneck.  When ``None``
                the model behaves as a standard UNet (backward compatible).

        Returns:
            (B, 1, H, W) violation heatmap logits.
        """
        # Step 1: encode the layout image into a hierarchy of skip features.
        if self.use_checkpointing and self.training:
            x, skip1 = grad_checkpoint(self.enc1, x, use_reentrant=False)
            x, skip2 = grad_checkpoint(self.enc2, x, use_reentrant=False)
            x, skip3 = grad_checkpoint(self.enc3, x, use_reentrant=False)
            x, skip4 = grad_checkpoint(self.enc4, x, use_reentrant=False)
            x = grad_checkpoint(self.bottleneck, x, use_reentrant=False)
        else:
            x, skip1 = self.enc1(x)
            x, skip2 = self.enc2(x)
            x, skip3 = self.enc3(x)
            x, skip4 = self.enc4(x)
            x = self.bottleneck(x)

        # Step 2: inject graph context at the bottleneck when conditioning is available.
        if self.film is not None and graph_cond is not None:
            x = self.film(x, graph_cond)

        # Step 3: decode with attention-gated skip connections back to image space.
        x = self.dec4(x, skip4)
        x = self.dec3(x, skip3)
        x = self.dec2(x, skip2)
        x = self.dec1(x, skip1)

        return self.head(x)


# ---------------------------------------------------------------------------
# Convenience helpers
# ---------------------------------------------------------------------------


# Alias for backward compatibility with external callers.
DRCRepairUNet = UNetRepair


def build_model(
    device: torch.device | str = "cpu",
    **kwargs,
) -> UNetRepair:
    """Create a UNetRepair and move it to the specified device.

    Args:
        device: Target device (e.g. "cpu", "cuda").
        **kwargs: Forwarded to UNetRepair.__init__.

    Returns:
        Initialised model on the requested device.
    """
    model = UNetRepair(**kwargs)
    return model.to(device)


if __name__ == "__main__":
    # --- Standard UNet (no FiLM) ---
    model = build_model()
    print(model)

    x = torch.randn(2, IN_CHANNELS, IMG_SIZE, IMG_SIZE)
    y = model(x)
    print(f"Input shape:  {x.shape}")
    print(f"Output shape: {y.shape}")
    total_params = sum(p.numel() for p in model.parameters())
    print(f"Total parameters (no FiLM): {total_params:,}")

    # --- UNet with FiLM conditioning ---
    film_model = build_model(use_film=True, film_cond_dim=64)
    cond = GraphConditioner(node_dim=12, hidden=64, out_dim=64)
    node_feats = torch.randn(2, 20, 12)  # 2 samples, 20 nodes, 12 features
    graph_emb = cond(node_feats)
    y_film = film_model(x, graph_cond=graph_emb)
    print(f"\nFiLM output shape: {y_film.shape}")
    film_params = sum(p.numel() for p in film_model.parameters())
    cond_params = sum(p.numel() for p in cond.parameters())
    print(f"UNet+FiLM parameters: {film_params:,}")
    print(f"GraphConditioner parameters: {cond_params:,}")
    print(f"FiLM overhead: {film_params - total_params + cond_params:,}")

    # --- Backward compat: FiLM model without graph_cond ---
    y_no_cond = film_model(x)
    print(f"FiLM model without cond: {y_no_cond.shape} (should match standard)")
