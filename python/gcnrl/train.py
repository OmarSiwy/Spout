"""PPO training loop for the GCN-RL Placement Agent.

Implements a simplified placement environment and Proximal Policy Optimisation
(PPO) for training the actor-critic GCN to place devices on a grid.

Primary metric: final placement cost (lower is better).
"""

from __future__ import annotations

import argparse
import logging
import math
import pathlib
from dataclasses import dataclass, field
from typing import Any

import numpy as np
import torch
import torch.nn as nn

from .model import (
    DEVICE_FEAT_DIM,
    GRID_SIZE,
    NODE_FEAT_DIM,
    NUM_ACTIONS,
    STATE_FEAT_DIM,
    GCNActorCritic,
    build_model,
)

# visualization
try:
    from ..visualizer import TrainingVisualizer as _TrainingVisualizer
except ImportError:
    _TrainingVisualizer = None  # type: ignore[assignment,misc]

logger = logging.getLogger(__name__)


def overlap_penalty_schedule(episode: int, total_episodes: int, start: float = 50.0, end: float = 5.0) -> float:
    """Cosine decay overlap penalty from start to end over training."""
    progress = min(episode / max(total_episodes, 1), 1.0)
    return end + 0.5 * (start - end) * (1.0 + math.cos(math.pi * progress))


# ---------------------------------------------------------------------------
# Symlog / symexp helpers (reward normalisation)
# ---------------------------------------------------------------------------


def symlog(x: torch.Tensor) -> torch.Tensor:
    """Symmetric logarithmic compression: sign(x) * log(1 + |x|).

    Compresses large magnitude rewards (e.g. 50.0 overlap penalties) into a
    range that is easier for the critic to learn, while preserving sign and
    monotonicity.
    """
    return torch.sign(x) * torch.log1p(x.abs())


def symexp(x: torch.Tensor) -> torch.Tensor:
    """Inverse of symlog: sign(x) * (exp(|x|) - 1)."""
    return torch.sign(x) * (torch.exp(x.abs()) - 1)


# ---------------------------------------------------------------------------
# Observation / return normalisation (ICLR 2021 PPO hygiene)
# ---------------------------------------------------------------------------


class RunningMeanStd:
    """Welford online mean/variance tracker for observation normalization."""

    def __init__(self, shape: tuple[int, ...] = (), clip: float = 5.0) -> None:
        self.mean = np.zeros(shape, dtype=np.float64)
        self.var = np.ones(shape, dtype=np.float64)
        self.count: float = 1e-4
        self.clip = clip

    def update(self, x: np.ndarray) -> None:
        batch_mean = np.mean(x, axis=0)
        batch_var = np.var(x, axis=0)
        batch_count = x.shape[0] if x.ndim > 1 else 1
        delta = batch_mean - self.mean
        tot_count = self.count + batch_count
        new_mean = self.mean + delta * batch_count / tot_count
        m_a = self.var * self.count
        m_b = batch_var * batch_count
        m2 = m_a + m_b + delta**2 * self.count * batch_count / tot_count
        self.mean = new_mean
        self.var = m2 / tot_count
        self.count = tot_count

    def normalize(self, x: np.ndarray) -> np.ndarray:
        return np.clip(
            (x - self.mean) / np.sqrt(self.var + 1e-8),
            -self.clip, self.clip,
        ).astype(np.float32)


class ReturnNormalizer:
    """Normalize rewards by running std of discounted returns (no mean subtraction).

    From "What Matters in On-Policy RL" (ICLR 2021): normalizing by return
    std stabilizes the value function without biasing the policy.
    """

    def __init__(self, gamma: float = 0.99) -> None:
        self.gamma = gamma
        self.ret_rms = RunningMeanStd(shape=())
        self._running_return: float = 0.0

    def normalize(self, rewards: list[float], dones: list[bool]) -> list[float]:
        # Update running return estimates.
        rets = []
        ret = 0.0
        for r, d in zip(reversed(rewards), reversed(dones)):
            if d:
                ret = 0.0
            ret = r + self.gamma * ret
            rets.insert(0, ret)
        self.ret_rms.update(np.array(rets))
        std = np.sqrt(self.ret_rms.var + 1e-8)
        return [r / std for r in rewards]


# ---------------------------------------------------------------------------
# Placement environment
# ---------------------------------------------------------------------------


@dataclass
class PlacementEnv:
    """Simplified placement environment for training.

    Devices are placed one at a time onto a GRID_SIZE x GRID_SIZE grid.
    The cost function penalises:
      - Wirelength: HPWL of connected device pairs.
      - Overlap: devices placed on the same grid cell.
      - Alignment: bonus for matching devices on the same row/column.

    The environment generates a random circuit graph at reset().
    """

    n_devices: int = 20
    n_edges: int = 60
    grid_size: int = GRID_SIZE
    seed: int | None = None
    overlap_penalty: float = 1.0

    # Internal state (populated on reset).
    _device_features: np.ndarray = field(init=False, repr=False, default_factory=lambda: np.array([]))
    _edge_index: np.ndarray = field(init=False, repr=False, default_factory=lambda: np.array([]))
    _placements: np.ndarray = field(init=False, repr=False, default_factory=lambda: np.array([]))
    _placed: np.ndarray = field(init=False, repr=False, default_factory=lambda: np.array([]))
    _step: int = field(init=False, default=0)
    _rng: np.random.Generator = field(init=False, repr=False, default_factory=lambda: np.random.default_rng())
    _visit_count: dict = field(init=False, repr=False, default_factory=dict)
    use_potential_shaping: bool = False
    _prev_potential: float = field(init=False, default=0.0)
    _shaping_gamma: float = 0.99

    def reset(self, seed: int | None = None) -> dict[str, torch.Tensor]:
        """Reset the environment, generating a new random circuit graph.

        Args:
            seed: Optional random seed for reproducibility.

        Returns:
            Initial observation dict with keys x, edge_index, batch,
            current_device_idx.
        """
        self._rng = np.random.default_rng(seed or self.seed)

        # Device features: type one-hot(6) + W, L, fingers, mult, x_init, y_init
        type_idx = self._rng.integers(0, 6, size=self.n_devices)
        type_onehot = np.zeros((self.n_devices, 6), dtype=np.float32)
        type_onehot[np.arange(self.n_devices), type_idx] = 1.0
        continuous = self._rng.standard_normal((self.n_devices, 6)).astype(np.float32)
        self._device_features = np.concatenate([type_onehot, continuous], axis=1)

        # Random circuit edges (between devices only).
        src = self._rng.integers(0, self.n_devices, size=self.n_edges).astype(np.int64)
        dst = self._rng.integers(0, self.n_devices, size=self.n_edges).astype(np.int64)
        self._edge_index = np.stack([src, dst])

        # Placement state.
        self._placements = np.zeros((self.n_devices, 2), dtype=np.float32)  # (grid_x, grid_y)
        self._placed = np.zeros(self.n_devices, dtype=np.float32)
        self._step = 0
        self._visit_count = {}
        self._prev_potential = 0.0  # Phi(s_0) = 0 since nothing is placed

        return self._get_obs()

    def _get_obs(self) -> dict[str, torch.Tensor]:
        """Build the current observation dict from internal placement state.

        Returns:
            Dict with keys x (node features), edge_index, batch, and
            current_device_idx pointing at the next device to place.
        """
        # State features per device: placed, grid_x, grid_y, step_fraction.
        step_frac = np.full(self.n_devices, self._step / max(self.n_devices, 1), dtype=np.float32)
        state = np.stack([
            self._placed,
            self._placements[:, 0] / self.grid_size,
            self._placements[:, 1] / self.grid_size,
            step_frac,
        ], axis=1)  # (N, 4)

        x = np.concatenate([self._device_features, state], axis=1)  # (N, 16)

        # Action mask: mark occupied grid cells as illegal.
        occupied = set()
        for j in range(self._step):
            occupied.add((int(self._placements[j][0]), int(self._placements[j][1])))
        mask = torch.ones(self.grid_size * self.grid_size, dtype=torch.bool)
        for r in range(self.grid_size):
            for c in range(self.grid_size):
                if (c, r) in occupied:
                    mask[r * self.grid_size + c] = False

        return {
            "x": torch.from_numpy(x),
            "edge_index": torch.from_numpy(self._edge_index.copy()),
            "batch": torch.zeros(self.n_devices, dtype=torch.long),
            "current_device_idx": torch.tensor([self._step]),
            "action_mask": mask,
        }

    def step(self, action: int) -> tuple[dict[str, torch.Tensor], float, bool]:
        """Place the current device at the grid position encoded by action.

        Args:
            action: integer in [0, GRID_SIZE^2), decoded as (row, col).

        Returns:
            (obs, reward, done)
        """
        row = action // self.grid_size
        col = action % self.grid_size

        self._placements[self._step] = [col, row]
        self._placed[self._step] = 1.0
        self._step += 1

        done = self._step >= self.n_devices

        # Compute step reward (negative incremental cost).
        reward = self._compute_step_reward()

        return self._get_obs(), reward, done

    def _compute_potential(self) -> float:
        """Potential function Phi(s) = -estimated_total_HPWL from partial placement.

        For each edge where at least one endpoint is placed, compute HPWL.
        For edges where neither endpoint is placed, contribute 0.
        """
        total_hpwl = 0.0
        src, dst = self._edge_index
        for e in range(len(src)):
            a, b = int(src[e]), int(dst[e])
            if self._placed[a] and self._placed[b]:
                dx = abs(self._placements[a][0] - self._placements[b][0])
                dy = abs(self._placements[a][1] - self._placements[b][1])
                total_hpwl += dx + dy
            elif self._placed[a] or self._placed[b]:
                # One endpoint placed: use distance from placed device to grid
                # centre as a conservative estimate.
                placed_idx = a if self._placed[a] else b
                cx = self.grid_size / 2.0
                cy = self.grid_size / 2.0
                dx = abs(self._placements[placed_idx][0] - cx)
                dy = abs(self._placements[placed_idx][1] - cy)
                total_hpwl += dx + dy
        return -total_hpwl

    def _compute_step_reward(self) -> float:
        """Negative incremental cost for the latest placement."""
        if self._step < 2:
            # Update potential even at step 0/1 so shaping starts correctly.
            if self.use_potential_shaping:
                self._prev_potential = self._compute_potential()
            return 0.0

        idx = self._step - 1
        pos_new = self._placements[idx]

        reward = 0.0

        # Wirelength penalty: HPWL to already-placed connected devices.
        src, dst = self._edge_index
        for e in range(len(src)):
            a, b = int(src[e]), int(dst[e])
            if (a == idx or b == idx) and self._placed[a] and self._placed[b]:
                dx = abs(self._placements[a][0] - self._placements[b][0])
                dy = abs(self._placements[a][1] - self._placements[b][1])
                reward -= (dx + dy) * 0.5

        # Overlap penalty (matches the 50.0 weight in compute_total_cost).
        overlap_occurred = False
        for j in range(self._step - 1):
            if (self._placements[j] == pos_new).all():
                reward -= self.overlap_penalty
                overlap_occurred = True

        # Intrinsic exploration bonus (count-based) -- only when no overlap.
        if not overlap_occurred:
            key = (float(pos_new[0]), float(pos_new[1]))
            count = self._visit_count.get(key, 0)
            self._visit_count[key] = count + 1
            reward += 0.05 / math.sqrt(count + 1)

        # Potential-based reward shaping (Ng et al., 1999).
        # F(s, s') = gamma * Phi(s') - Phi(s)
        # This is provably optimal-policy-preserving.
        if self.use_potential_shaping:
            new_potential = self._compute_potential()
            shaping = self._shaping_gamma * new_potential - self._prev_potential
            reward += shaping
            self._prev_potential = new_potential

        return float(reward)

    def compute_total_cost(self) -> float:
        """Compute total placement cost after all devices are placed."""
        cost = 0.0

        # Wirelength: sum of HPWL over all edges.
        src, dst = self._edge_index
        for e in range(len(src)):
            a, b = int(src[e]), int(dst[e])
            dx = abs(self._placements[a][0] - self._placements[b][0])
            dy = abs(self._placements[a][1] - self._placements[b][1])
            cost += dx + dy

        # Overlap penalty.
        occupied: dict[tuple[float, float], int] = {}
        for i in range(self.n_devices):
            key = (self._placements[i][0], self._placements[i][1])
            occupied[key] = occupied.get(key, 0) + 1
        for count in occupied.values():
            if count > 1:
                cost += (count - 1) * 50.0  # heavy penalty

        return float(cost)


# ---------------------------------------------------------------------------
# PPO rollout buffer
# ---------------------------------------------------------------------------


@dataclass
class RolloutBuffer:
    """Stores trajectories for PPO updates."""

    observations: list[dict[str, torch.Tensor]] = field(default_factory=list)
    actions: list[int] = field(default_factory=list)
    log_probs: list[float] = field(default_factory=list)
    rewards: list[float] = field(default_factory=list)
    values: list[float] = field(default_factory=list)
    dones: list[bool] = field(default_factory=list)

    def clear(self) -> None:
        """Reset all trajectory lists to empty."""
        self.observations.clear()
        self.actions.clear()
        self.log_probs.clear()
        self.rewards.clear()
        self.values.clear()
        self.dones.clear()

    def __len__(self) -> int:
        """Return the number of stored transitions."""
        return len(self.actions)


# ---------------------------------------------------------------------------
# PPO training
# ---------------------------------------------------------------------------


def compute_gae(
    rewards: list[float],
    values: list[float],
    dones: list[bool],
    gamma: float = 0.99,
    lam: float = 0.95,
) -> tuple[list[float], list[float]]:
    """Compute Generalised Advantage Estimation (GAE-lambda).

    Args:
        rewards: Per-step rewards from the rollout.
        values: Per-step value estimates from the critic.
        dones: Per-step episode termination flags.
        gamma: Discount factor.
        lam: GAE lambda parameter controlling bias-variance trade-off.

    Returns:
        (advantages, returns): Both lists of length len(rewards).
    """
    advantages = []
    returns = []
    gae = 0.0
    next_value = 0.0

    for t in reversed(range(len(rewards))):
        if dones[t]:
            next_value = 0.0
            gae = 0.0

        delta = rewards[t] + gamma * next_value - values[t]
        gae = delta + gamma * lam * gae
        advantages.insert(0, gae)
        returns.insert(0, gae + values[t])
        next_value = values[t]

    return advantages, returns


def _ppo_update_base(
    *,
    model: GCNActorCritic,
    optimiser: torch.optim.Optimizer,
    buffer: RolloutBuffer,
    ppo_epochs: int,
    gamma: float,
    gae_lambda: float,
    clip_eps: float,
    entropy_coef: float,
    value_coef: float,
    max_grad_norm: float,
    device: torch.device,
    grad_accum_steps: int = 1,
    use_edge_features: bool = False,
    scaler: torch.amp.GradScaler | None = None,
    use_amp: bool = False,
    use_symlog: bool = False,
    episode: int = 0,
) -> None:
    """Run PPO update epochs over the rollout buffer.

    Shared by the GCN and Transformer training loops.  Handles GAE
    computation, advantage normalisation, and clipped PPO loss with
    optional gradient accumulation.

    When *use_symlog* is True the critic targets are compressed via
    ``symlog`` so that extreme reward values (overlap penalties, varying
    HPWL) are mapped into a learnable range.
    """
    advantages, returns = compute_gae(
        buffer.rewards, buffer.values, buffer.dones,
        gamma=gamma, lam=gae_lambda,
    )
    adv_t = torch.tensor(advantages, dtype=torch.float32, device=device)
    ret_t = torch.tensor(returns, dtype=torch.float32, device=device)
    old_log_probs_t = torch.tensor(buffer.log_probs, dtype=torch.float32, device=device)
    actions_t = torch.tensor(buffer.actions, dtype=torch.long, device=device)

    # Symlog reward normalisation: compress returns into symlog space so the
    # critic predicts symlog(return) instead of raw returns.  Advantages are
    # normalised separately and remain untouched.
    if use_symlog:
        ret_t = symlog(ret_t)

    # Normalise advantages.
    if adv_t.numel() > 1:
        adv_t = (adv_t - adv_t.mean()) / (adv_t.std() + 1e-8)

    # Resolve AMP helpers – fall back to no-op when caller does not provide them.
    if scaler is None:
        scaler = torch.amp.GradScaler("cuda", enabled=False)

    n_transitions = len(buffer)
    minibatch_size = min(64, n_transitions)

    model.train()
    for _ in range(ppo_epochs):
        # Minibatch shuffling: random permutation over all transitions.
        perm = torch.randperm(n_transitions)
        for mb_start in range(0, n_transitions, minibatch_size):
            mb_indices = perm[mb_start:mb_start + minibatch_size]
            total_loss = torch.tensor(0.0, device=device)

            for t_idx in mb_indices:
                t = t_idx.item()
                obs_t = buffer.observations[t]
                x = obs_t["x"].to(device)
                ei = obs_t["edge_index"].to(device)
                bat = obs_t["batch"].to(device)
                cidx = obs_t["current_device_idx"].to(device)

                # Build keyword args for models that support edge features.
                kwargs: dict[str, Any] = {"action": actions_t[t:t+1]}
                if use_edge_features:
                    ea = obs_t.get("edge_attr")
                    if ea is not None:
                        kwargs["edge_attr"] = ea.to(device) if hasattr(ea, "to") else ea

                # Re-apply action mask stored during rollout collection.
                amask = obs_t.get("action_mask")
                if amask is not None:
                    kwargs["action_mask"] = amask.unsqueeze(0).to(device)

                with torch.amp.autocast("cuda", enabled=use_amp):
                    _, new_log_prob, entropy, new_value = model.get_action_and_value(
                        x, ei, bat, cidx, **kwargs,
                    )

                    # PPO clipped objective.
                    ratio = torch.exp(new_log_prob - old_log_probs_t[t])
                    surr1 = ratio * adv_t[t]
                    surr2 = torch.clamp(ratio, 1 - clip_eps, 1 + clip_eps) * adv_t[t]
                    policy_loss = -torch.min(surr1, surr2)

                    # Simple MSE value loss (no clipping — ICLR 2021 showed it hurts).
                    value_loss = (new_value - ret_t[t]) ** 2

                    entropy_loss = -entropy

                    total_loss = total_loss + policy_loss + value_coef * value_loss + entropy_coef * entropy_loss

            optimiser.zero_grad()
            total_loss = total_loss / len(mb_indices)
            scaler.scale(total_loss).backward()
            scaler.unscale_(optimiser)
            if episode % 50 == 0:
                total_norm = sum(p.grad.data.norm(2).item() ** 2 for p in model.parameters() if p.grad is not None) ** 0.5
                logger.info("Episode %d grad_norm=%.4f", episode, total_norm)
            nn.utils.clip_grad_norm_(model.parameters(), max_grad_norm)
            scaler.step(optimiser)
            scaler.update()


def train(
    *,
    n_episodes: int = 500,
    n_devices: int = 20,
    n_edges: int = 60,
    ppo_epochs: int = 4,
    lr: float = 3e-4,
    gamma: float = 0.99,
    gae_lambda: float = 0.98,
    clip_eps: float = 0.2,
    entropy_coef: float = 0.03,
    value_coef: float = 0.5,
    max_grad_norm: float = 0.5,
    update_every: int = 10,
    device: str | torch.device = "cpu",
    checkpoint_dir: str | pathlib.Path = "checkpoints/gcnrl",
    verbose: bool = True,
    use_symlog: bool = False,
    use_potential_shaping: bool = False,
    viz: Any = None,
) -> dict[str, Any]:
    """PPO training loop for the GCN-RL placement agent.

    Args:
        n_episodes: Total number of placement episodes.
        n_devices: Number of devices per circuit graph.
        n_edges: Number of circuit edges per graph.
        ppo_epochs: Number of optimisation passes per PPO update.
        lr: Adam learning rate.
        gamma: Discount factor for GAE.
        gae_lambda: Lambda for GAE bias-variance trade-off.
        clip_eps: PPO clipping epsilon.
        entropy_coef: Coefficient for the entropy bonus term.
        value_coef: Coefficient for the value loss term.
        max_grad_norm: Gradient clipping max norm.
        update_every: How many episodes to collect before each PPO update.
        device: Compute device (e.g. "cpu", "cuda").
        checkpoint_dir: Directory to save model checkpoints.
        verbose: Log progress every 50 episodes.
        use_symlog: Compress critic targets with symlog for stabler learning.
        use_potential_shaping: Add potential-based reward shaping (Ng 1999).

    Returns:
        Dict with keys best_placement_cost, episodes_trained, history, checkpoint.
    """
    device = torch.device(device)
    checkpoint_dir = pathlib.Path(checkpoint_dir)
    checkpoint_dir.mkdir(parents=True, exist_ok=True)

    model = build_model(device=device)

    # torch.compile for graph-level kernel fusion (PyTorch 2+).
    if hasattr(torch, "compile"):
        model = torch.compile(model)

    # Mixed-precision: only enable on CUDA devices.
    use_amp = "cuda" in str(device)
    scaler = torch.amp.GradScaler("cuda", enabled=use_amp)

    optimiser = torch.optim.Adam(model.parameters(), lr=lr)
    # Cosine annealing LR: decay from lr to lr/10 over training.
    lr_scheduler = torch.optim.lr_scheduler.CosineAnnealingLR(
        optimiser, T_max=n_episodes // update_every, eta_min=lr * 0.1,
    )

    env = PlacementEnv(n_devices=n_devices, n_edges=n_edges)
    env.use_potential_shaping = use_potential_shaping
    buffer = RolloutBuffer()

    # Observation normalization: running mean/std on node features, clip to [-5,5].
    obs_rms = RunningMeanStd(shape=(NODE_FEAT_DIM,), clip=5.0)
    # Return normalization: running std of discounted returns (no mean subtraction).
    ret_norm = ReturnNormalizer(gamma=gamma)

    best_cost = math.inf
    history: dict[str, list[float]] = {"episode_cost": [], "episode_reward": []}

    for episode in range(1, n_episodes + 1):
        progress = (episode - 1) / max(n_episodes - 1, 1)
        # Cosine decay: overlap penalty 50x -> 5x over training.
        env.overlap_penalty = overlap_penalty_schedule(episode, n_episodes)

        # Curriculum: ramp n_devices from 10 to target over first 60% of training.
        curriculum_progress = min(1.0, progress / 0.6)
        env.n_devices = max(10, int(10 + (n_devices - 10) * curriculum_progress))
        env.n_edges = int(env.n_devices * (n_edges / max(n_devices, 1)))

        obs = env.reset(seed=episode)
        episode_reward = 0.0
        done = False

        while not done:
            # Observation normalization: update stats and normalize node features.
            raw_x = obs["x"].numpy()
            obs_rms.update(raw_x)
            obs["x"] = torch.from_numpy(obs_rms.normalize(raw_x))

            x = obs["x"].to(device)
            ei = obs["edge_index"].to(device)
            bat = obs["batch"].to(device)
            cidx = obs["current_device_idx"].to(device)

            amask = obs["action_mask"].unsqueeze(0).to(device)

            model.eval()
            with torch.no_grad(), torch.amp.autocast("cuda", enabled=use_amp):
                action, log_prob, _, value = model.get_action_and_value(
                    x, ei, bat, cidx, action_mask=amask,
                )

            action_int = action.item()
            buffer.observations.append(obs)
            buffer.actions.append(action_int)
            buffer.log_probs.append(log_prob.item())
            buffer.values.append(value.item())

            obs, reward, done = env.step(action_int)
            buffer.rewards.append(reward)
            buffer.dones.append(done)
            episode_reward += reward

        total_cost = env.compute_total_cost()
        history["episode_cost"].append(total_cost)
        history["episode_reward"].append(episode_reward)

        # visualization
        if viz is not None:
            viz.update(episode, {"reward": episode_reward, "episode_cost": total_cost})

        # -- PPO update every `update_every` episodes --
        if episode % update_every == 0 and len(buffer) > 0:
            # Return-based reward normalization (ICLR 2021: running std, no mean).
            buffer.rewards = ret_norm.normalize(buffer.rewards, buffer.dones)

            # Entropy bonus: decays linearly from entropy_coef to 0 over training.
            ent_coef = entropy_coef * max(0.0, 1.0 - episode / n_episodes)
            _ppo_update_base(
                model=model,
                optimiser=optimiser,
                buffer=buffer,
                ppo_epochs=ppo_epochs,
                gamma=gamma,
                gae_lambda=gae_lambda,
                clip_eps=clip_eps,
                entropy_coef=ent_coef,
                value_coef=value_coef,
                max_grad_norm=max_grad_norm,
                device=device,
                scaler=scaler,
                use_amp=use_amp,
                use_symlog=use_symlog,
                episode=episode,
            )
            buffer.clear()
            lr_scheduler.step()

        # -- Checkpoint --
        if total_cost < best_cost:
            best_cost = total_cost
            # Save the unwrapped state dict when torch.compile is used.
            raw_model = getattr(model, "_orig_mod", model)
            ckpt = {
                "episode": episode,
                "model_state_dict": raw_model.state_dict(),
                "optimiser_state_dict": optimiser.state_dict(),
                "placement_cost": total_cost,
            }
            torch.save(ckpt, checkpoint_dir / "best_model.pt")

        if verbose and (episode % 50 == 0 or episode == 1):
            recent_costs = history["episode_cost"][-50:]
            avg_cost = sum(recent_costs) / len(recent_costs)
            logger.info(
                "Episode %4d/%d  cost=%.1f  avg_cost(50)=%.1f  best=%.1f",
                episode,
                n_episodes,
                total_cost,
                avg_cost,
                best_cost,
            )

    return {
        "best_placement_cost": best_cost,
        "episodes_trained": n_episodes,
        "history": history,
        "checkpoint": str(checkpoint_dir / "best_model.pt"),
    }


def train_transformer(**kwargs):
    """Run the transformer placement trainer housed in the shared utility layer."""
    from ..utility.transformer_training import train_transformer as _train_transformer

    return _train_transformer(**kwargs)


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------


def main() -> None:
    """CLI entry point: parse arguments and launch the PPO training loop."""
    logging.basicConfig(level=logging.INFO, format="%(levelname)s: %(message)s")

    parser = argparse.ArgumentParser(description="Train GCN-RL Placement Agent")
    parser.add_argument("--n-episodes", type=int, default=500)
    parser.add_argument("--n-devices", type=int, default=20)
    parser.add_argument("--n-edges", type=int, default=60)
    parser.add_argument("--ppo-epochs", type=int, default=4)
    parser.add_argument("--lr", type=float, default=3e-4)
    parser.add_argument("--clip-eps", type=float, default=0.2)
    parser.add_argument("--update-every", type=int, default=10)
    parser.add_argument("--device", type=str, default="cpu")
    parser.add_argument(
        "--checkpoint-dir", type=str, default="checkpoints/gcnrl"
    )
    parser.add_argument(
        "--use-symlog", action=argparse.BooleanOptionalAction, default=False,
        help="Compress critic targets with symlog (default: off)",
    )
    parser.add_argument(
        "--use-potential-shaping", action=argparse.BooleanOptionalAction, default=False,
        help="Potential-based reward shaping (Ng 1999) (default: on)",
    )
    # visualization
    parser.add_argument(
        "--viz",
        action="store_true",
        default=False,
        help="Enable training visualization (saves PNG plots; live window if DISPLAY is set).",
    )
    args = parser.parse_args()

    # visualization
    _viz = None
    if args.viz and _TrainingVisualizer is not None:
        import os as _os
        _viz = _TrainingVisualizer(
            model_name="gcnrl",
            metrics=["reward", "episode_cost"],
            output_dir=args.checkpoint_dir,
            save_every=10,
            live=bool(_os.environ.get("DISPLAY") or _os.environ.get("WAYLAND_DISPLAY")),
            x_label="episode",
        )

    result = train(
        n_episodes=args.n_episodes,
        n_devices=args.n_devices,
        n_edges=args.n_edges,
        ppo_epochs=args.ppo_epochs,
        lr=args.lr,
        clip_eps=args.clip_eps,
        update_every=args.update_every,
        device=args.device,
        checkpoint_dir=args.checkpoint_dir,
        use_symlog=args.use_symlog,
        use_potential_shaping=args.use_potential_shaping,
        viz=_viz,
    )

    # visualization
    if _viz is not None:
        _viz.finish()

    logger.info(
        "Training complete. Best placement cost: %.1f",
        result["best_placement_cost"],
    )
    logger.info("Checkpoint saved to: %s", result["checkpoint"])


if __name__ == "__main__":
    main()


def transfer_gcn_to_transformer(
    model,
    gcn_path: str,
    device: str | torch.device = "cpu",
) -> None:
    """Warm-start a transformer policy from a compatible GCN checkpoint."""
    from ..utility import transformer_training as _transformer_training

    _transformer_training._warm_start_from_gcn(model, gcn_path, torch.device(device))
