"""RL-based DRC repair agent.

Takes a violation heatmap from the UNet + device positions, and learns to
make small position adjustments that reduce DRC violations.

Architecture follows NVCell (NVIDIA, DAC 2021):
    - State:  flattened violation heatmap features + per-device features
    - Action: per-device (dx, dy) displacement (continuous, bounded)
    - Reward: reduction in violation count after applying corrections

The agent operates iteratively: predict corrections -> apply -> re-evaluate
-> repeat until violations reach zero or max iterations.

Training uses PPO (Proximal Policy Optimisation) on a lightweight synthetic
environment that generates random layouts with spacing violations and lets the
agent learn to nudge devices apart.

Typical training: ~500 episodes, ~5 min on CPU, ~500 K parameters.
"""

from __future__ import annotations

import argparse
import logging
import math
import pathlib
from typing import Any, Optional

import numpy as np
import torch
import torch.nn as nn
import torch.nn.functional as F

logger = logging.getLogger(__name__)


# ---------------------------------------------------------------------------
# Policy network
# ---------------------------------------------------------------------------


class DRCRepairPolicy(nn.Module):
    """Actor-critic policy for DRC repair.

    The actor outputs per-device (dx, dy) corrections bounded by tanh to
    [-1, 1], scaled at inference time by the caller's grid step.  The critic
    estimates the state value for advantage computation.

    Args:
        max_devices: Maximum number of devices the policy supports.
        heatmap_size: Spatial resolution after adaptive pooling (H=W).
        hidden_dim: Width of hidden layers.
    """

    def __init__(
        self,
        max_devices: int = 20,
        heatmap_size: int = 32,
        hidden_dim: int = 128,
    ) -> None:
        super().__init__()
        self.max_devices = max_devices
        self.heatmap_size = heatmap_size

        # Heatmap encoder: adaptive pool -> flatten -> linear.
        self.heatmap_encoder = nn.Sequential(
            nn.AdaptiveAvgPool2d(heatmap_size),
            nn.Flatten(),
            nn.Linear(heatmap_size * heatmap_size, hidden_dim),
            nn.ReLU(),
        )

        # Per-device features: (x, y, width, height, type_id, violation_intensity).
        device_feat_dim = max_devices * 6
        self.device_encoder = nn.Sequential(
            nn.Linear(device_feat_dim, hidden_dim),
            nn.ReLU(),
        )

        # Shared trunk.
        self.shared = nn.Sequential(
            nn.Linear(hidden_dim * 2, hidden_dim),
            nn.ReLU(),
            nn.Linear(hidden_dim, hidden_dim),
            nn.ReLU(),
        )

        # Actor head: mean of Gaussian per (dx, dy).
        self.actor_mean = nn.Linear(hidden_dim, max_devices * 2)
        self.actor_log_std = nn.Parameter(torch.zeros(max_devices * 2))

        # Critic head.
        self.critic = nn.Linear(hidden_dim, 1)

        self._init_weights()

    def _init_weights(self) -> None:
        for m in self.modules():
            if isinstance(m, nn.Linear):
                nn.init.orthogonal_(m.weight, gain=math.sqrt(2))
                if m.bias is not None:
                    nn.init.zeros_(m.bias)
        # Smaller initialisation for actor output to start near zero corrections.
        nn.init.orthogonal_(self.actor_mean.weight, gain=0.01)
        nn.init.zeros_(self.actor_mean.bias)

    def forward(
        self,
        heatmap: torch.Tensor,
        device_features: torch.Tensor,
    ) -> tuple[torch.Tensor, torch.Tensor, torch.Tensor]:
        """Forward pass.

        Args:
            heatmap: (B, 1, H, W) violation probability map.
            device_features: (B, max_devices * 6) flattened device features.

        Returns:
            action_mean:  (B, max_devices * 2) bounded to [-1, 1].
            action_std:   (B, max_devices * 2) positive standard deviations.
            value:        (B, 1) estimated state value.
        """
        h = self.heatmap_encoder(heatmap)
        d = self.device_encoder(device_features)
        shared = self.shared(torch.cat([h, d], dim=-1))

        action_mean = torch.tanh(self.actor_mean(shared))
        action_std = self.actor_log_std.exp().expand_as(action_mean)
        value = self.critic(shared)

        return action_mean, action_std, value


# ---------------------------------------------------------------------------
# Synthetic DRC environment
# ---------------------------------------------------------------------------


class DRCRepairEnv:
    """Lightweight environment for training the RL repair agent.

    Generates random device placements on a grid, some of which violate
    minimum-spacing rules.  The agent's job is to nudge devices so that all
    spacing constraints are satisfied.

    State:
        - Violation heatmap rasterised from current device positions.
        - Per-device features: (norm_x, norm_y, norm_w, norm_h, type, viol).

    Action:
        - (n_devices * 2,) continuous displacements, each in [-1, 1],
          scaled internally by ``max_step``.

    Reward:
        - ``old_violations - new_violations`` (positive when violations drop).
        - Bonus of +5.0 for reaching zero violations.

    Args:
        grid_size: Spatial extent of the layout canvas.
        n_devices: Number of devices per episode.
        min_spacing: Minimum spacing rule (grid units).
        max_step: Maximum single-step displacement (grid units).
        max_devices: Padding dimension (must match policy).
    """

    def __init__(
        self,
        grid_size: int = 64,
        n_devices: int = 10,
        min_spacing: int = 3,
        max_step: float = 2.0,
        max_devices: int = 20,
    ) -> None:
        self.grid_size = grid_size
        self.n_devices = n_devices
        self.min_spacing = min_spacing
        self.max_step = max_step
        self.max_devices = max_devices

        # Device state: (x, y, w, h, type).
        self.positions: np.ndarray = np.zeros((n_devices, 2), dtype=np.float32)
        self.sizes: np.ndarray = np.zeros((n_devices, 2), dtype=np.float32)
        self.types: np.ndarray = np.zeros(n_devices, dtype=np.int32)
        self.rng = np.random.default_rng()

    def reset(self, seed: Optional[int] = None) -> tuple[torch.Tensor, torch.Tensor]:
        """Generate a fresh random layout, potentially with spacing violations.

        Returns:
            (heatmap, device_features) tensors ready for the policy.
        """
        if seed is not None:
            self.rng = np.random.default_rng(seed)

        gs = self.grid_size
        n = self.n_devices

        # Random device sizes.
        self.sizes = self.rng.integers(3, 10, size=(n, 2)).astype(np.float32)
        self.types = self.rng.integers(0, 5, size=n).astype(np.int32)

        # Place some devices with deliberate spacing violations.
        self.positions = np.zeros((n, 2), dtype=np.float32)
        for i in range(n):
            self.positions[i, 0] = self.rng.uniform(
                self.sizes[i, 0], gs - self.sizes[i, 0]
            )
            self.positions[i, 1] = self.rng.uniform(
                self.sizes[i, 1], gs - self.sizes[i, 1]
            )

        # Force ~40 % of device pairs to be close enough to violate spacing.
        n_close = max(1, n // 3)
        for i in range(n_close):
            j = (i + 1) % n
            gap = self.rng.uniform(0.5, self.min_spacing - 0.5)
            direction = self.rng.choice([-1.0, 1.0])
            self.positions[j, 0] = (
                self.positions[i, 0]
                + direction * (self.sizes[i, 0] / 2 + self.sizes[j, 0] / 2 + gap)
            )
            self.positions[j, 1] = self.positions[i, 1] + self.rng.uniform(-2, 2)

        # Clamp inside grid.
        self._clamp_positions()

        return self._get_state()

    def step(
        self, action: np.ndarray
    ) -> tuple[tuple[torch.Tensor, torch.Tensor], float, bool]:
        """Apply corrections, recompute violations, return (state, reward, done).

        Args:
            action: (max_devices * 2,) array; only the first n_devices * 2
                    values are used.  Each pair is (dx, dy) in [-1, 1],
                    scaled by ``self.max_step``.

        Returns:
            state:  (heatmap, device_features) tuple.
            reward: ``old_violations - new_violations`` plus bonus for clean.
            done:   True when violations reach zero.
        """
        old_violations = self._compute_violations()

        # Apply corrections (only for actual devices, ignore padding).
        n = self.n_devices
        dx = action[:n * 2].reshape(n, 2) * self.max_step
        self.positions += dx
        self._clamp_positions()

        new_violations = self._compute_violations()
        reward = float(old_violations - new_violations)

        # Bonus for reaching zero.
        done = new_violations == 0
        if done:
            reward += 5.0

        state = self._get_state()
        return state, reward, done

    # -- internal helpers ---------------------------------------------------

    def _clamp_positions(self) -> None:
        """Keep devices within the grid, accounting for their sizes."""
        for i in range(self.n_devices):
            half_w = self.sizes[i, 0] / 2
            half_h = self.sizes[i, 1] / 2
            self.positions[i, 0] = np.clip(
                self.positions[i, 0], half_w, self.grid_size - half_w
            )
            self.positions[i, 1] = np.clip(
                self.positions[i, 1], half_h, self.grid_size - half_h
            )

    def _compute_violations(self) -> int:
        """Count pairwise spacing violations between all devices."""
        n = self.n_devices
        count = 0
        for i in range(n):
            for j in range(i + 1, n):
                # Axis-aligned gap between bounding boxes.
                gap_x = abs(self.positions[i, 0] - self.positions[j, 0]) - (
                    self.sizes[i, 0] + self.sizes[j, 0]
                ) / 2
                gap_y = abs(self.positions[i, 1] - self.positions[j, 1]) - (
                    self.sizes[i, 1] + self.sizes[j, 1]
                ) / 2
                # Overlap or gap below min_spacing on BOTH axes means violation.
                if gap_x < self.min_spacing and gap_y < self.min_spacing:
                    count += 1
        return count

    def _get_heatmap(self) -> torch.Tensor:
        """Rasterise current layout to a 1-channel violation heatmap.

        Returns:
            (1, 1, grid_size, grid_size) float tensor with violation
            probabilities in [0, 1].
        """
        gs = self.grid_size
        heatmap = np.zeros((gs, gs), dtype=np.float32)
        n = self.n_devices

        for i in range(n):
            for j in range(i + 1, n):
                gap_x = abs(self.positions[i, 0] - self.positions[j, 0]) - (
                    self.sizes[i, 0] + self.sizes[j, 0]
                ) / 2
                gap_y = abs(self.positions[i, 1] - self.positions[j, 1]) - (
                    self.sizes[i, 1] + self.sizes[j, 1]
                ) / 2

                if gap_x < self.min_spacing and gap_y < self.min_spacing:
                    # Mark the region between the two devices.
                    cx = (self.positions[i, 0] + self.positions[j, 0]) / 2
                    cy = (self.positions[i, 1] + self.positions[j, 1]) / 2
                    # Violation extent: union of the two devices' bounding boxes.
                    rx = int(
                        (self.sizes[i, 0] + self.sizes[j, 0]) / 2
                        + self.min_spacing
                    )
                    ry = int(
                        (self.sizes[i, 1] + self.sizes[j, 1]) / 2
                        + self.min_spacing
                    )
                    x0 = max(0, int(cx) - rx)
                    x1 = min(gs, int(cx) + rx)
                    y0 = max(0, int(cy) - ry)
                    y1 = min(gs, int(cy) + ry)
                    # Intensity proportional to how badly the rule is violated.
                    severity = 1.0 - max(gap_x, gap_y) / self.min_spacing
                    severity = float(np.clip(severity, 0.1, 1.0))
                    heatmap[y0:y1, x0:x1] = np.maximum(
                        heatmap[y0:y1, x0:x1], severity
                    )

        return torch.from_numpy(heatmap).unsqueeze(0).unsqueeze(0)  # (1,1,H,W)

    def _get_device_features(self) -> torch.Tensor:
        """Build the padded device feature vector.

        Per device: (norm_x, norm_y, norm_w, norm_h, type / 5, violation_intensity).
        Padded to max_devices with zeros.

        Returns:
            (1, max_devices * 6) float tensor.
        """
        n = self.n_devices
        gs = float(self.grid_size)
        feats = np.zeros((self.max_devices, 6), dtype=np.float32)

        # Per-device violation intensity: max heatmap value at device centre.
        heatmap_np = self._get_heatmap().squeeze().numpy()

        for i in range(n):
            px = int(np.clip(self.positions[i, 0], 0, gs - 1))
            py = int(np.clip(self.positions[i, 1], 0, gs - 1))
            feats[i, 0] = self.positions[i, 0] / gs
            feats[i, 1] = self.positions[i, 1] / gs
            feats[i, 2] = self.sizes[i, 0] / gs
            feats[i, 3] = self.sizes[i, 1] / gs
            feats[i, 4] = self.types[i] / 5.0
            feats[i, 5] = float(heatmap_np[py, px])

        return torch.from_numpy(feats.flatten()).unsqueeze(0)  # (1, max_devices*6)

    def _get_state(self) -> tuple[torch.Tensor, torch.Tensor]:
        """Return (heatmap, device_features) tensors."""
        return self._get_heatmap(), self._get_device_features()


# ---------------------------------------------------------------------------
# PPO rollout buffer
# ---------------------------------------------------------------------------


class RolloutBuffer:
    """Simple buffer that collects PPO trajectory data for one epoch."""

    def __init__(self) -> None:
        self.heatmaps: list[torch.Tensor] = []
        self.device_feats: list[torch.Tensor] = []
        self.actions: list[torch.Tensor] = []
        self.log_probs: list[torch.Tensor] = []
        self.rewards: list[float] = []
        self.values: list[float] = []
        self.dones: list[bool] = []

    def store(
        self,
        heatmap: torch.Tensor,
        device_feat: torch.Tensor,
        action: torch.Tensor,
        log_prob: torch.Tensor,
        reward: float,
        value: float,
        done: bool,
    ) -> None:
        self.heatmaps.append(heatmap)
        self.device_feats.append(device_feat)
        self.actions.append(action)
        self.log_probs.append(log_prob)
        self.rewards.append(reward)
        self.values.append(value)
        self.dones.append(done)

    def compute_returns(
        self, gamma: float = 0.99, lam: float = 0.95
    ) -> tuple[torch.Tensor, torch.Tensor]:
        """Compute GAE advantages and discounted returns.

        Returns:
            (returns, advantages): each of shape (T,).
        """
        T = len(self.rewards)
        returns = torch.zeros(T)
        advantages = torch.zeros(T)

        last_gae = 0.0
        last_value = 0.0

        for t in reversed(range(T)):
            if self.dones[t]:
                next_value = 0.0
                last_gae = 0.0
            else:
                next_value = self.values[t + 1] if t + 1 < T else last_value
            delta = self.rewards[t] + gamma * next_value - self.values[t]
            last_gae = delta + gamma * lam * last_gae
            advantages[t] = last_gae
            returns[t] = advantages[t] + self.values[t]

        return returns, advantages

    def clear(self) -> None:
        self.heatmaps.clear()
        self.device_feats.clear()
        self.actions.clear()
        self.log_probs.clear()
        self.rewards.clear()
        self.values.clear()
        self.dones.clear()

    def __len__(self) -> int:
        return len(self.rewards)


# ---------------------------------------------------------------------------
# PPO update
# ---------------------------------------------------------------------------


def _ppo_update(
    policy: DRCRepairPolicy,
    optimiser: torch.optim.Optimizer,
    buf: RolloutBuffer,
    clip_eps: float = 0.2,
    value_coeff: float = 0.5,
    entropy_coeff: float = 0.01,
    n_epochs: int = 4,
    gamma: float = 0.99,
    lam: float = 0.95,
    device: torch.device = torch.device("cpu"),
) -> dict[str, float]:
    """Run PPO mini-batch updates on the collected rollout.

    Returns:
        Dict with mean policy_loss, value_loss, entropy, total_loss.
    """
    returns, advantages = buf.compute_returns(gamma=gamma, lam=lam)

    # Stack trajectory data.
    heatmaps = torch.cat(buf.heatmaps, dim=0).to(device)        # (T,1,H,W)
    dev_feats = torch.cat(buf.device_feats, dim=0).to(device)   # (T, D)
    old_actions = torch.stack(buf.actions).to(device)             # (T, A)
    old_log_probs = torch.stack(buf.log_probs).to(device)        # (T,)
    returns = returns.to(device)
    advantages = advantages.to(device)

    # Normalise advantages.
    if advantages.numel() > 1:
        advantages = (advantages - advantages.mean()) / (advantages.std() + 1e-8)

    total_policy_loss = 0.0
    total_value_loss = 0.0
    total_entropy = 0.0
    n_updates = 0

    for _ in range(n_epochs):
        mean, std, values = policy(heatmaps, dev_feats)
        values = values.squeeze(-1)

        # Gaussian log-probability of the old actions under current policy.
        dist = torch.distributions.Normal(mean, std)
        new_log_probs = dist.log_prob(old_actions).sum(dim=-1)
        entropy = dist.entropy().sum(dim=-1).mean()

        # PPO clipped objective.
        ratio = torch.exp(new_log_probs - old_log_probs)
        surr1 = ratio * advantages
        surr2 = torch.clamp(ratio, 1.0 - clip_eps, 1.0 + clip_eps) * advantages
        policy_loss = -torch.min(surr1, surr2).mean()

        value_loss = F.mse_loss(values, returns)

        loss = policy_loss + value_coeff * value_loss - entropy_coeff * entropy

        optimiser.zero_grad()
        loss.backward()
        nn.utils.clip_grad_norm_(policy.parameters(), max_norm=0.5)
        optimiser.step()

        total_policy_loss += policy_loss.item()
        total_value_loss += value_loss.item()
        total_entropy += entropy.item()
        n_updates += 1

    return {
        "policy_loss": total_policy_loss / max(n_updates, 1),
        "value_loss": total_value_loss / max(n_updates, 1),
        "entropy": total_entropy / max(n_updates, 1),
    }


# ---------------------------------------------------------------------------
# Training entry point
# ---------------------------------------------------------------------------


def train_rl_repair(
    *,
    n_episodes: int = 500,
    max_steps: int = 20,
    lr: float = 3e-4,
    gamma: float = 0.99,
    lam: float = 0.95,
    clip_eps: float = 0.2,
    ppo_epochs: int = 4,
    n_devices: int = 10,
    grid_size: int = 64,
    min_spacing: int = 3,
    max_devices: int = 20,
    heatmap_size: int = 32,
    hidden_dim: int = 128,
    device: str | torch.device = "cpu",
    checkpoint_dir: str | pathlib.Path = "checkpoints/unet_rl",
    verbose: bool = True,
    seed: int = 42,
) -> dict[str, Any]:
    """Train the RL repair agent with PPO.

    Generates synthetic layouts with spacing violations, lets the agent
    iteratively correct positions, and trains with PPO on the resulting
    trajectories.

    Args:
        n_episodes: Number of training episodes.
        max_steps: Maximum correction steps per episode.
        lr: Learning rate for Adam.
        gamma: Discount factor.
        lam: GAE lambda.
        clip_eps: PPO clip epsilon.
        ppo_epochs: PPO optimisation epochs per rollout.
        n_devices: Devices per synthetic layout.
        grid_size: Canvas size for the environment.
        min_spacing: Minimum spacing rule (grid units).
        max_devices: Padding dimension for the policy.
        heatmap_size: Heatmap pooling size for the policy.
        hidden_dim: Hidden layer width.
        device: Torch device.
        checkpoint_dir: Where to save checkpoints.
        verbose: Whether to log progress.
        seed: Random seed.

    Returns:
        Dict with training history and best episode reward.
    """
    device = torch.device(device)
    checkpoint_dir = pathlib.Path(checkpoint_dir)
    checkpoint_dir.mkdir(parents=True, exist_ok=True)

    torch.manual_seed(seed)
    np.random.seed(seed)

    env = DRCRepairEnv(
        grid_size=grid_size,
        n_devices=n_devices,
        min_spacing=min_spacing,
        max_devices=max_devices,
    )

    policy = DRCRepairPolicy(
        max_devices=max_devices,
        heatmap_size=heatmap_size,
        hidden_dim=hidden_dim,
    ).to(device)

    total_params = sum(p.numel() for p in policy.parameters())
    logger.info("RL repair policy parameters: %s", f"{total_params:,}")

    optimiser = torch.optim.Adam(policy.parameters(), lr=lr)

    history: dict[str, list[float]] = {
        "episode_reward": [],
        "episode_violations": [],
        "episode_steps": [],
        "policy_loss": [],
        "value_loss": [],
    }
    best_avg_reward = -float("inf")
    buf = RolloutBuffer()

    for episode in range(1, n_episodes + 1):
        heatmap, dev_feats = env.reset(seed=seed + episode)
        episode_reward = 0.0
        steps = 0

        for step in range(max_steps):
            heatmap_d = heatmap.to(device)
            dev_feats_d = dev_feats.to(device)

            with torch.no_grad():
                mean, std, value = policy(heatmap_d, dev_feats_d)

            # Sample action from Gaussian.
            dist = torch.distributions.Normal(mean, std)
            action = dist.sample()
            action = torch.clamp(action, -1.0, 1.0)
            log_prob = dist.log_prob(action).sum(dim=-1)

            action_np = action.squeeze(0).cpu().numpy()
            (heatmap, dev_feats), reward, done = env.step(action_np)

            buf.store(
                heatmap=heatmap_d,
                device_feat=dev_feats_d,
                action=action.squeeze(0),
                log_prob=log_prob.squeeze(0),
                reward=reward,
                value=value.squeeze().item(),
                done=done,
            )

            episode_reward += reward
            steps += 1

            if done:
                break

        # PPO update at the end of each episode.
        if len(buf) >= max_steps // 2:
            losses = _ppo_update(
                policy,
                optimiser,
                buf,
                clip_eps=clip_eps,
                n_epochs=ppo_epochs,
                gamma=gamma,
                lam=lam,
                device=device,
            )
            history["policy_loss"].append(losses["policy_loss"])
            history["value_loss"].append(losses["value_loss"])
            buf.clear()

        final_violations = env._compute_violations()
        history["episode_reward"].append(episode_reward)
        history["episode_violations"].append(float(final_violations))
        history["episode_steps"].append(float(steps))

        # Checkpoint on rolling-average reward.
        window = min(20, len(history["episode_reward"]))
        avg_reward = sum(history["episode_reward"][-window:]) / window
        if avg_reward > best_avg_reward:
            best_avg_reward = avg_reward
            ckpt = {
                "episode": episode,
                "model_state_dict": policy.state_dict(),
                "optimiser_state_dict": optimiser.state_dict(),
                "avg_reward": avg_reward,
                "max_devices": max_devices,
                "heatmap_size": heatmap_size,
                "hidden_dim": hidden_dim,
            }
            torch.save(ckpt, checkpoint_dir / "best_model.pt")

        if verbose and (episode % 25 == 0 or episode == 1):
            logger.info(
                "Episode %4d/%d  reward=%+6.1f  violations=%d  steps=%d  "
                "avg_reward=%.1f",
                episode,
                n_episodes,
                episode_reward,
                final_violations,
                steps,
                avg_reward,
            )

    # Save final checkpoint.
    final_ckpt = {
        "episode": n_episodes,
        "model_state_dict": policy.state_dict(),
        "optimiser_state_dict": optimiser.state_dict(),
        "avg_reward": avg_reward,
        "max_devices": max_devices,
        "heatmap_size": heatmap_size,
        "hidden_dim": hidden_dim,
    }
    torch.save(final_ckpt, checkpoint_dir / "final_model.pt")

    return {
        "best_avg_reward": best_avg_reward,
        "episodes_trained": n_episodes,
        "history": history,
        "checkpoint": str(checkpoint_dir / "best_model.pt"),
    }


# ---------------------------------------------------------------------------
# Inference
# ---------------------------------------------------------------------------

# Default checkpoint path relative to project root.
_DEFAULT_RL_CHECKPOINT = "checkpoints/unet_rl/best_model.pt"


def _find_rl_checkpoint() -> pathlib.Path:
    """Locate the RL repair model checkpoint, searching from this file upward."""
    current = pathlib.Path(__file__).resolve().parent
    for _ in range(10):
        candidate = current / _DEFAULT_RL_CHECKPOINT
        if candidate.exists():
            return candidate
        if (current / "build.zig").exists():
            return candidate
        parent = current.parent
        if parent == current:
            break
        current = parent
    return pathlib.Path(_DEFAULT_RL_CHECKPOINT)


def predict_rl_repair(
    device_positions: list[tuple[float, float]] | np.ndarray,
    device_features: list[tuple[float, float, int]] | np.ndarray,
    heatmap: np.ndarray,
    model_path: Optional[str | pathlib.Path] = None,
    max_iterations: int = 10,
    max_step: float = 2.0,
    device: str | torch.device = "cpu",
) -> tuple[np.ndarray, int]:
    """Use a trained RL agent to iteratively repair DRC violations.

    The agent takes the UNet violation heatmap and device positions, then
    predicts small (dx, dy) corrections per device.  It runs for up to
    ``max_iterations`` passes, re-evaluating violations after each.

    Args:
        device_positions: (N, 2) or list of (x, y) device centres.
        device_features: (N, 3) or list of (width, height, type_id).
        heatmap: 2D numpy array (H, W) from UNet prediction (probabilities).
        model_path: Path to RL checkpoint; auto-detected if None.
        max_iterations: Maximum correction passes.
        max_step: Physical displacement per step (grid units).
        device: Torch device for inference.

    Returns:
        corrected_positions: (N, 2) array of corrected (x, y) positions.
        n_violations_remaining: estimated remaining violation count.

    Raises:
        FileNotFoundError: If no RL checkpoint is found.
    """
    device = torch.device(device)

    # Normalise inputs.
    positions = np.array(device_positions, dtype=np.float32)
    if positions.ndim == 1:
        positions = positions.reshape(-1, 2)
    features = np.array(device_features, dtype=np.float32)
    if features.ndim == 1:
        features = features.reshape(-1, 3)

    n_devices = positions.shape[0]
    if n_devices == 0:
        return positions.copy(), 0

    # Load checkpoint.
    if model_path is None:
        ckpt_path = _find_rl_checkpoint()
    else:
        ckpt_path = pathlib.Path(model_path)

    if not ckpt_path.exists():
        raise FileNotFoundError(
            f"RL repair checkpoint not found at {ckpt_path}"
        )

    ckpt = torch.load(ckpt_path, map_location=device, weights_only=True)
    max_devices = ckpt.get("max_devices", 20)
    heatmap_size = ckpt.get("heatmap_size", 32)
    hidden_dim = ckpt.get("hidden_dim", 128)

    policy = DRCRepairPolicy(
        max_devices=max_devices,
        heatmap_size=heatmap_size,
        hidden_dim=hidden_dim,
    ).to(device)
    policy.load_state_dict(ckpt["model_state_dict"])
    policy.eval()

    # Prepare heatmap tensor (1, 1, H, W).
    hm = heatmap.astype(np.float32)
    if hm.ndim == 2:
        hm = hm[np.newaxis, np.newaxis, :, :]
    elif hm.ndim == 3:
        hm = hm[np.newaxis, :, :, :]
    hm_tensor = torch.from_numpy(hm).to(device)

    # Working copy of positions.
    corrected = positions.copy()

    # Bounding box for normalisation.
    x_min, y_min = corrected.min(axis=0)
    x_max, y_max = corrected.max(axis=0)
    span = max(float(x_max - x_min), float(y_max - y_min), 1e-6)

    for iteration in range(max_iterations):
        # Build device feature vector (padded to max_devices * 6).
        dev_feat = np.zeros((max_devices, 6), dtype=np.float32)
        for i in range(min(n_devices, max_devices)):
            dev_feat[i, 0] = (corrected[i, 0] - x_min) / span
            dev_feat[i, 1] = (corrected[i, 1] - y_min) / span
            dev_feat[i, 2] = features[i, 0] / span if features.shape[1] > 0 else 0
            dev_feat[i, 3] = features[i, 1] / span if features.shape[1] > 1 else 0
            dev_feat[i, 4] = features[i, 2] / 5.0 if features.shape[1] > 2 else 0
            # Violation intensity at this device from the heatmap.
            hm_h, hm_w = heatmap.shape[-2], heatmap.shape[-1]
            px = int(np.clip(dev_feat[i, 0] * (hm_w - 1), 0, hm_w - 1))
            py = int(np.clip(dev_feat[i, 1] * (hm_h - 1), 0, hm_h - 1))
            dev_feat[i, 5] = float(heatmap[py, px]) if heatmap.ndim == 2 else 0.0

        dev_feat_tensor = torch.from_numpy(dev_feat.flatten()).unsqueeze(0).to(device)

        with torch.no_grad():
            mean, _, _ = policy(hm_tensor, dev_feat_tensor)

        # Use mean (deterministic) for inference.
        action = mean.squeeze(0).cpu().numpy()  # (max_devices * 2,)
        dx = action[: n_devices * 2].reshape(n_devices, 2) * max_step
        corrected += dx

        # Check if corrections are negligible (converged).
        if np.abs(dx).max() < max_step * 0.01:
            break

    # Estimate remaining violations from heatmap intensity at corrected positions.
    n_violations = 0
    for i in range(n_devices):
        nx = (corrected[i, 0] - x_min) / span
        ny = (corrected[i, 1] - y_min) / span
        hm_h, hm_w = heatmap.shape[-2], heatmap.shape[-1]
        px = int(np.clip(nx * (hm_w - 1), 0, hm_w - 1))
        py = int(np.clip(ny * (hm_h - 1), 0, hm_h - 1))
        if heatmap.ndim == 2 and heatmap[py, px] > 0.5:
            n_violations += 1

    logger.info(
        "predict_rl_repair: %d devices, %d iterations, %d estimated violations remaining",
        n_devices,
        iteration + 1,
        n_violations,
    )

    return corrected, n_violations


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------


def main() -> None:
    """CLI entry point: parse arguments and launch RL repair training."""
    logging.basicConfig(level=logging.INFO, format="%(levelname)s: %(message)s")

    parser = argparse.ArgumentParser(
        description="Train RL DRC Repair Agent (PPO)"
    )
    parser.add_argument("--n-episodes", type=int, default=500)
    parser.add_argument("--max-steps", type=int, default=20)
    parser.add_argument("--lr", type=float, default=3e-4)
    parser.add_argument("--gamma", type=float, default=0.99)
    parser.add_argument("--n-devices", type=int, default=10)
    parser.add_argument("--grid-size", type=int, default=64)
    parser.add_argument("--min-spacing", type=int, default=3)
    parser.add_argument("--max-devices", type=int, default=20)
    parser.add_argument("--hidden-dim", type=int, default=128)
    parser.add_argument("--device", type=str, default="cpu")
    parser.add_argument(
        "--checkpoint-dir", type=str, default="checkpoints/unet_rl"
    )
    parser.add_argument("--seed", type=int, default=42)
    args = parser.parse_args()

    result = train_rl_repair(
        n_episodes=args.n_episodes,
        max_steps=args.max_steps,
        lr=args.lr,
        gamma=args.gamma,
        n_devices=args.n_devices,
        grid_size=args.grid_size,
        min_spacing=args.min_spacing,
        max_devices=args.max_devices,
        hidden_dim=args.hidden_dim,
        device=args.device,
        checkpoint_dir=args.checkpoint_dir,
        seed=args.seed,
    )

    logger.info(
        "RL training complete. Best avg reward: %.1f", result["best_avg_reward"]
    )
    logger.info("Checkpoint saved to: %s", result["checkpoint"])


if __name__ == "__main__":
    main()
