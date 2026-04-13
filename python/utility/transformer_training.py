"""PPO training loop with curriculum learning for the Graph Transformer.

Implements:
  - Curriculum learning: start with 5-10 devices, scale to 50+
  - Hybrid mode: Transformer seed -> SA refinement (optional, via callback)
  - Warm-start from GCN checkpoint (distillation-compatible)
  - Gradient accumulation for larger effective batch sizes
  - Cosine annealing learning rate schedule

The training environment is the same PlacementEnv from train.py, but
with configurable device counts driven by the curriculum.
"""

from __future__ import annotations

import argparse
import logging
import math
import pathlib
from dataclasses import dataclass, field
from typing import Any, Callable

import numpy as np
import torch

from .graph_transformer import (
    EDGE_FEAT_DIM,
    NUM_ACTIONS,
    GraphTransformerActorCritic,
    build_transformer_model,
    compute_edge_features,
)
from ..gcnrl.train import PlacementEnv, RolloutBuffer, _ppo_update_base

logger = logging.getLogger(__name__)


# ---------------------------------------------------------------------------
# Curriculum schedule
# ---------------------------------------------------------------------------


@dataclass
class CurriculumStage:
    """A single stage in the curriculum."""

    n_devices: int
    n_edges: int
    episodes: int  # episodes to train at this stage


@dataclass
class CurriculumSchedule:
    """Curriculum learning schedule: ramp device count over training.

    Default schedule:
      Stage 1: 5 devices, 15 edges, 100 episodes
      Stage 2: 10 devices, 30 edges, 150 episodes
      Stage 3: 20 devices, 60 edges, 200 episodes
      Stage 4: 35 devices, 120 edges, 200 episodes
      Stage 5: 50 devices, 200 edges, 250 episodes
    """

    stages: list[CurriculumStage] = field(default_factory=lambda: [
        CurriculumStage(n_devices=5, n_edges=15, episodes=100),
        CurriculumStage(n_devices=10, n_edges=30, episodes=150),
        CurriculumStage(n_devices=20, n_edges=60, episodes=200),
        CurriculumStage(n_devices=35, n_edges=120, episodes=200),
        CurriculumStage(n_devices=50, n_edges=200, episodes=250),
    ])

    @property
    def total_episodes(self) -> int:
        """Total number of training episodes across all curriculum stages."""
        return sum(s.episodes for s in self.stages)


# ---------------------------------------------------------------------------
# Hybrid SA callback type
# ---------------------------------------------------------------------------

# A callable that takes (positions: np.ndarray, circuit_info: dict) and
# returns refined_positions: np.ndarray.  This is how the Zig SA engine
# is invoked from the training loop when hybrid mode is enabled.
SaRefineCallback = Callable[[np.ndarray, dict], np.ndarray]


# ---------------------------------------------------------------------------
# Training loop
# ---------------------------------------------------------------------------


def train_transformer(
    *,
    curriculum: CurriculumSchedule | None = None,
    ppo_epochs: int = 4,
    lr: float = 1e-4,
    min_lr: float = 1e-6,
    gamma: float = 0.99,
    gae_lambda: float = 0.95,
    clip_eps: float = 0.2,
    entropy_coef: float = 0.02,
    value_coef: float = 0.5,
    max_grad_norm: float = 1.0,
    update_every: int = 5,
    grad_accum_steps: int = 2,
    device: str | torch.device = "cpu",
    checkpoint_dir: str | pathlib.Path = "checkpoints/transformer",
    gcn_checkpoint: str | None = None,
    sa_refine_callback: SaRefineCallback | None = None,
    use_edge_features: bool = True,
    verbose: bool = True,
    # Model hyperparameters.
    d_model: int = 192,
    n_layers: int = 6,
    n_heads: int = 8,
    d_ff: int = 512,
    spectral_k: int = 8,
    model_dropout: float = 0.1,
) -> dict[str, Any]:
    """PPO training loop with curriculum learning for the Graph Transformer.

    Parameters
    ----------
    curriculum : CurriculumSchedule, optional
        Curriculum stages.  Defaults to the standard 5-stage schedule.
    ppo_epochs : int
        Number of PPO mini-epochs per update.
    lr : float
        Peak learning rate.
    min_lr : float
        Minimum learning rate for cosine annealing.
    gamma, gae_lambda : float
        GAE discount and lambda.
    clip_eps : float
        PPO clipping epsilon.
    entropy_coef : float
        Entropy bonus coefficient (higher for exploration).
    value_coef : float
        Value loss coefficient.
    max_grad_norm : float
        Gradient clipping norm.
    update_every : int
        PPO update frequency (in episodes).
    grad_accum_steps : int
        Gradient accumulation steps within each PPO update.
    device : str or torch.device
        Compute device.
    checkpoint_dir : str or Path
        Where to save model checkpoints.
    gcn_checkpoint : str, optional
        Path to a trained GCN model checkpoint for warm-start.
    sa_refine_callback : callable, optional
        If provided, enables hybrid mode: after the Transformer places all
        devices, this callback runs SA refinement and the refined cost is
        used as the training signal.
    use_edge_features : bool
        Whether to compute and use edge features.
    verbose : bool
        Log progress.
    d_model, n_layers, n_heads, d_ff, spectral_k, model_dropout
        Model architecture hyperparameters.

    Returns
    -------
    dict with training history and best placement cost.
    """
    if curriculum is None:
        curriculum = CurriculumSchedule()

    device = torch.device(device)
    checkpoint_dir = pathlib.Path(checkpoint_dir)
    checkpoint_dir.mkdir(parents=True, exist_ok=True)

    # Build model.
    edge_dim = EDGE_FEAT_DIM if use_edge_features else 0
    model = build_transformer_model(
        device=device,
        d_model=d_model,
        n_layers=n_layers,
        n_heads=n_heads,
        d_ff=d_ff,
        num_actions=NUM_ACTIONS,
        spectral_k=spectral_k,
        edge_feat_dim=edge_dim,
        dropout=model_dropout,
    )

    total_params = sum(p.numel() for p in model.parameters())
    logger.info("GraphTransformerActorCritic: %d parameters (%.2fM)", total_params, total_params / 1e6)

    # torch.compile() for graph-mode speedup (PyTorch 2+).
    try:
        model = torch.compile(model)
        logger.info("torch.compile() applied to Transformer model")
    except Exception:
        pass  # torch.compile not available on this setup

    # Optional warm-start from GCN checkpoint.
    if gcn_checkpoint:
        _warm_start_from_gcn(model, gcn_checkpoint, device)

    optimiser = torch.optim.AdamW(
        model.parameters(), lr=lr, weight_decay=1e-4
    )

    # Cosine annealing over total episodes.
    total_episodes = curriculum.total_episodes
    scheduler = torch.optim.lr_scheduler.CosineAnnealingLR(
        optimiser, T_max=total_episodes, eta_min=min_lr
    )

    buffer = RolloutBuffer()
    best_cost = math.inf
    global_episode = 0

    history: dict[str, list[float]] = {
        "episode_cost": [],
        "episode_reward": [],
        "stage": [],
        "n_devices": [],
        "lr": [],
    }

    # --- Curriculum loop ---
    for stage_idx, stage in enumerate(curriculum.stages):
        if verbose:
            logger.info(
                "=== Curriculum Stage %d/%d: %d devices, %d edges, %d episodes ===",
                stage_idx + 1,
                len(curriculum.stages),
                stage.n_devices,
                stage.n_edges,
                stage.episodes,
            )

        env = PlacementEnv(
            n_devices=stage.n_devices,
            n_edges=stage.n_edges,
        )

        for ep in range(1, stage.episodes + 1):
            global_episode += 1
            obs = env.reset(seed=global_episode)
            episode_reward = 0.0
            done = False

            while not done:
                x = obs["x"].to(device)
                ei = obs["edge_index"].to(device)
                bat = obs["batch"].to(device)
                cidx = obs["current_device_idx"].to(device)

                # Compute edge features if enabled.
                ea = None
                if use_edge_features and ei.shape[1] > 0:
                    ea = compute_edge_features(
                        ei, n_nodes=x.shape[0]
                    ).to(device)

                model.eval()
                with torch.no_grad():
                    action, log_prob, _, value = model.get_action_and_value(
                        x, ei, bat, cidx, edge_attr=ea,
                    )

                action_int = action.item()
                buffer.observations.append({**obs, "edge_attr": ea})
                buffer.actions.append(action_int)
                buffer.log_probs.append(log_prob.item())
                buffer.values.append(value.item())

                obs, reward, done = env.step(action_int)
                buffer.rewards.append(reward)
                buffer.dones.append(done)
                episode_reward += reward

            # Compute total cost.
            total_cost = env.compute_total_cost()

            # Hybrid mode: SA refinement of the Transformer's placement.
            if sa_refine_callback is not None:
                try:
                    positions = env._placements.copy()
                    circuit_info = {
                        "edge_index": env._edge_index.copy(),
                        "n_devices": env.n_devices,
                        "grid_size": env.grid_size,
                    }
                    refined = sa_refine_callback(positions, circuit_info)
                    # Recompute cost with refined positions.
                    env._placements[:] = refined
                    refined_cost = env.compute_total_cost()
                    # Reward shaping: bonus for SA improvement.
                    improvement = total_cost - refined_cost
                    if improvement > 0 and len(buffer.rewards) > 0:
                        buffer.rewards[-1] += improvement * 0.1
                        episode_reward += improvement * 0.1
                    total_cost = refined_cost
                except Exception as exc:
                    logger.debug("SA refinement failed: %s", exc)

            history["episode_cost"].append(total_cost)
            history["episode_reward"].append(episode_reward)
            history["stage"].append(stage_idx)
            history["n_devices"].append(stage.n_devices)
            history["lr"].append(optimiser.param_groups[0]["lr"])

            # --- PPO update ---
            if global_episode % update_every == 0 and len(buffer) > 0:
                _ppo_update_base(
                    model=model,
                    optimiser=optimiser,
                    buffer=buffer,
                    ppo_epochs=ppo_epochs,
                    gamma=gamma,
                    gae_lambda=gae_lambda,
                    clip_eps=clip_eps,
                    entropy_coef=entropy_coef,
                    value_coef=value_coef,
                    max_grad_norm=max_grad_norm,
                    grad_accum_steps=grad_accum_steps,
                    device=device,
                    use_edge_features=use_edge_features,
                )
                buffer.clear()

            # Step scheduler.
            scheduler.step()

            # --- Checkpoint ---
            if total_cost < best_cost:
                best_cost = total_cost
                ckpt = {
                    "global_episode": global_episode,
                    "stage_idx": stage_idx,
                    "model_state_dict": model.state_dict(),
                    "optimiser_state_dict": optimiser.state_dict(),
                    "placement_cost": total_cost,
                    "n_devices": stage.n_devices,
                    "total_params": total_params,
                }
                torch.save(ckpt, checkpoint_dir / "best_model.pt")

            if verbose and (ep % 50 == 0 or ep == 1):
                recent_costs = history["episode_cost"][-50:]
                avg_cost = sum(recent_costs) / len(recent_costs)
                current_lr = optimiser.param_groups[0]["lr"]
                logger.info(
                    "  [Stage %d] Episode %4d/%d (global %d)  "
                    "cost=%.1f  avg(50)=%.1f  best=%.1f  lr=%.2e",
                    stage_idx + 1,
                    ep,
                    stage.episodes,
                    global_episode,
                    total_cost,
                    avg_cost,
                    best_cost,
                    current_lr,
                )

        # Save stage checkpoint.
        torch.save(
            {
                "global_episode": global_episode,
                "stage_idx": stage_idx,
                "model_state_dict": model.state_dict(),
                "optimiser_state_dict": optimiser.state_dict(),
            },
            checkpoint_dir / f"stage_{stage_idx + 1}.pt",
        )

    # Final checkpoint.
    torch.save(
        {
            "global_episode": global_episode,
            "model_state_dict": model.state_dict(),
            "optimiser_state_dict": optimiser.state_dict(),
            "best_cost": best_cost,
            "total_params": total_params,
        },
        checkpoint_dir / "final_model.pt",
    )

    return {
        "best_placement_cost": best_cost,
        "episodes_trained": global_episode,
        "history": history,
        "checkpoint": str(checkpoint_dir / "best_model.pt"),
        "total_params": total_params,
    }


# ---------------------------------------------------------------------------
# GCN warm-start (knowledge transfer)
# ---------------------------------------------------------------------------


def _warm_start_from_gcn(
    model: GraphTransformerActorCritic,
    gcn_path: str,
    device: torch.device,
) -> None:
    """Transfer compatible weights from a trained GCN checkpoint.

    Loads actor and critic head weights where shapes match, allowing the
    Transformer to start from a partially trained policy.
    """
    try:
        ckpt = torch.load(gcn_path, map_location=device, weights_only=True)
        gcn_state = ckpt.get("model_state_dict", ckpt)

        model_state = model.state_dict()
        transferred = 0

        for key, param in gcn_state.items():
            # Try to match actor/critic head weights.
            if key in model_state and model_state[key].shape == param.shape:
                model_state[key] = param
                transferred += 1

        model.load_state_dict(model_state, strict=False)
        logger.info(
            "Warm-started from GCN checkpoint: %d/%d parameters transferred",
            transferred,
            len(gcn_state),
        )
    except Exception as exc:
        logger.warning("Could not warm-start from GCN: %s", exc)


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------


def main() -> None:
    """CLI entry point: parse arguments and launch the curriculum training loop."""
    logging.basicConfig(
        level=logging.INFO, format="%(levelname)s: %(message)s"
    )

    parser = argparse.ArgumentParser(
        description="Train Graph Transformer Placement Agent (curriculum)"
    )
    parser.add_argument("--device", type=str, default="cpu")
    parser.add_argument(
        "--checkpoint-dir", type=str, default="checkpoints/transformer"
    )
    parser.add_argument("--gcn-checkpoint", type=str, default=None)
    parser.add_argument("--lr", type=float, default=1e-4)
    parser.add_argument("--ppo-epochs", type=int, default=4)
    parser.add_argument("--update-every", type=int, default=5)
    parser.add_argument("--d-model", type=int, default=192)
    parser.add_argument("--n-layers", type=int, default=6)
    parser.add_argument("--n-heads", type=int, default=8)
    parser.add_argument(
        "--no-edge-features", action="store_true",
        help="Disable edge features",
    )
    args = parser.parse_args()

    result = train_transformer(
        device=args.device,
        checkpoint_dir=args.checkpoint_dir,
        gcn_checkpoint=args.gcn_checkpoint,
        lr=args.lr,
        ppo_epochs=args.ppo_epochs,
        update_every=args.update_every,
        d_model=args.d_model,
        n_layers=args.n_layers,
        n_heads=args.n_heads,
        use_edge_features=not args.no_edge_features,
    )

    logger.info(
        "Training complete. Best placement cost: %.1f  (%d params)",
        result["best_placement_cost"],
        result["total_params"],
    )
    logger.info("Checkpoint saved to: %s", result["checkpoint"])


if __name__ == "__main__":
    main()
