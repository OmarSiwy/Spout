"""
Spout training data harvester — extract features from netlists for ML training.

Provides three extraction modes:
  1. **Surrogate features** — 69-dimensional float vector for the placement
     cost surrogate model.
  2. **Graph features** — adjacency + node/edge attribute tensors for the
     GNN encoder.
  3. **Batch harvest** — process an entire directory of SPICE designs and
     write features to disk.

Usage (CLI)::

    python -m python_refactor.utility.data_harvester designs/ --output features/ --format npz
"""

from __future__ import annotations

import json
import logging
import os
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Optional

import numpy as np

logger = logging.getLogger(__name__)

# ---------------------------------------------------------------------------
# Result / container types
# ---------------------------------------------------------------------------


@dataclass
class SurrogateFeatures:
    """69-dimensional feature vector for the placement cost surrogate.

    Layout:
      [0:8]   — global stats (num_devices, num_nets, num_pins, ...)
      [8:24]  — device-type histogram (16 bins)
      [24:40] — W/L distribution stats (mean, std, min, max per type group)
      [40:56] — net fanout distribution stats
      [56:64] — constraint summary features
      [64:69] — placement cost components (HPWL, area, sym, match, RUDY)
    """

    vector: np.ndarray  # shape (69,), float32
    design_name: str = ""


@dataclass
class GraphFeatures:
    """Circuit graph representation for GNN training.

    The bipartite graph has device nodes and net hyperedges decomposed into
    device-pin-net edges.
    """

    # Node features: (num_devices, node_feat_dim)
    node_features: np.ndarray
    # Edge index: (2, num_edges) — COO format [device_idx, net_idx]
    edge_index: np.ndarray
    # Edge features: (num_edges, edge_feat_dim) — terminal type one-hot etc.
    edge_features: np.ndarray
    # Labels (optional): placement cost or positions
    labels: Optional[np.ndarray] = None
    design_name: str = ""

    @property
    def num_nodes(self) -> int:
        """Number of device nodes in the graph."""
        return int(self.node_features.shape[0])

    @property
    def num_edges(self) -> int:
        """Number of pin edges (device-to-net connections) in the graph."""
        return int(self.edge_index.shape[1])


@dataclass
class HarvestResult:
    """Result of harvesting a single design."""

    design_name: str
    netlist_path: str
    surrogate: Optional[SurrogateFeatures] = None
    graph: Optional[GraphFeatures] = None
    placement_cost: float = 0.0
    success: bool = False
    error: Optional[str] = None


# ---------------------------------------------------------------------------
# Surrogate feature extraction
# ---------------------------------------------------------------------------

# Number of device type bins for the histogram.
_NUM_TYPE_BINS = 16


def extract_surrogate_features(
    arrays: dict,
    placement_cost: float = 0.0,
    design_name: str = "",
) -> SurrogateFeatures:
    """Build a 69-dim feature vector from the Zig-side array data.

    Parameters
    ----------
    arrays : dict
        Output of ``SpoutFFI.get_all_arrays(handle)``.
    placement_cost : float
        Final placement cost (used as partial label for the last 5 dims).
    design_name : str
        Identifier for this design.

    Returns
    -------
    SurrogateFeatures
        The 69-dimensional feature vector.
    """
    vec = np.zeros(69, dtype=np.float32)

    num_devices = int(arrays.get("num_devices", 0))
    num_nets = int(arrays.get("num_nets", 0))
    num_pins = int(arrays.get("num_pins", 0))

    # ── [0:8] Global statistics ──────────────────────────────────────
    vec[0] = num_devices
    vec[1] = num_nets
    vec[2] = num_pins
    vec[3] = num_pins / max(num_devices, 1)  # avg pins per device
    vec[4] = num_pins / max(num_nets, 1)  # avg fanout
    vec[5] = num_nets / max(num_devices, 1)  # net-to-device ratio

    positions = arrays.get("device_positions", np.empty((0, 2)))
    if positions.size > 0:
        bbox = positions.max(axis=0) - positions.min(axis=0)
        vec[6] = bbox[0] * bbox[1]  # bounding-box area
        vec[7] = bbox[0] / max(bbox[1], 1e-9)  # aspect ratio

    # ── [8:24] Device type histogram ─────────────────────────────────
    device_types = arrays.get("device_types", np.empty(0, dtype=np.uint8))
    if device_types.size > 0:
        hist, _ = np.histogram(
            device_types, bins=_NUM_TYPE_BINS, range=(0, _NUM_TYPE_BINS)
        )
        vec[8:24] = hist.astype(np.float32)

    # ── [24:40] W/L distribution stats ───────────────────────────────
    device_params = arrays.get("device_params", np.empty((0, 5)))
    if device_params.size > 0 and device_params.shape[0] > 0:
        widths = device_params[:, 0]
        lengths = device_params[:, 1]

        vec[24] = np.mean(widths)
        vec[25] = np.std(widths)
        vec[26] = np.min(widths)
        vec[27] = np.max(widths)
        vec[28] = np.mean(lengths)
        vec[29] = np.std(lengths)
        vec[30] = np.min(lengths)
        vec[31] = np.max(lengths)

        # W/L ratio stats
        wl_ratio = widths / np.maximum(lengths, 1e-12)
        vec[32] = np.mean(wl_ratio)
        vec[33] = np.std(wl_ratio)
        vec[34] = np.min(wl_ratio)
        vec[35] = np.max(wl_ratio)

        # Per-type group stats (NMOS vs PMOS) based on type <=7 vs >7
        if device_types.size == device_params.shape[0]:
            nmos_mask = device_types <= 7
            pmos_mask = device_types > 7
            if np.any(nmos_mask):
                vec[36] = np.mean(widths[nmos_mask])
                vec[37] = np.mean(lengths[nmos_mask])
            if np.any(pmos_mask):
                vec[38] = np.mean(widths[pmos_mask])
                vec[39] = np.mean(lengths[pmos_mask])

    # ── [40:56] Net fanout distribution ──────────────────────────────
    fanout = arrays.get("net_fanout", np.empty(0, dtype=np.uint16))
    if fanout.size > 0:
        fanout_f = fanout.astype(np.float32)
        vec[40] = np.mean(fanout_f)
        vec[41] = np.std(fanout_f)
        vec[42] = np.min(fanout_f)
        vec[43] = np.max(fanout_f)
        vec[44] = np.median(fanout_f)

        # Fanout histogram (bins: 1, 2, 3, 4, 5-8, 9-16, 17-32, 33+)
        edges = [0, 1, 2, 3, 4, 8, 16, 32, max(int(fanout_f.max()) + 1, 33)]
        hist, _ = np.histogram(fanout_f, bins=edges)
        # Pad or truncate to 8 bins
        hist_f = hist[:8].astype(np.float32)
        vec[45 : 45 + len(hist_f)] = hist_f

        # High-fanout net count (fanout >= 10)
        vec[53] = float(np.sum(fanout >= 10))
        vec[54] = float(np.sum(fanout >= 20))
        vec[55] = float(np.sum(fanout >= 50))

    # ── [56:64] Constraint summary ───────────────────────────────────
    # These would come from the constraint buffer, but we leave them
    # as zero placeholders when constraints are not available.
    # The caller can fill them in from ffi.get_constraints() data.

    # ── [64:69] Placement cost components ────────────────────────────
    vec[64] = placement_cost
    # Slots 65-68 reserved for individual cost terms (HPWL, area, sym, match)
    # which can be filled by the caller if available.

    return SurrogateFeatures(vector=vec, design_name=design_name)


# ---------------------------------------------------------------------------
# Graph feature extraction
# ---------------------------------------------------------------------------


def extract_graph_features(
    arrays: dict,
    placement_cost: float = 0.0,
    design_name: str = "",
) -> GraphFeatures:
    """Build a circuit graph from the Zig-side array data.

    The graph is bipartite: device nodes connected to net nodes via pin edges.

    Parameters
    ----------
    arrays : dict
        Output of ``SpoutFFI.get_all_arrays(handle)``.
    placement_cost : float
        Final placement cost (stored as graph-level label).
    design_name : str
        Identifier for this design.

    Returns
    -------
    GraphFeatures
        Graph tensors in COO format.
    """
    num_devices = int(arrays.get("num_devices", 0))
    num_nets = int(arrays.get("num_nets", 0))
    num_pins = int(arrays.get("num_pins", 0))

    # ── Node features ────────────────────────────────────────────────
    # Per-device: [type_onehot(16), w, l, fingers, mult, value, x, y] = 23 dim
    node_feat_dim = 23
    node_features = np.zeros((num_devices, node_feat_dim), dtype=np.float32)

    device_types = arrays.get("device_types", np.empty(0, dtype=np.uint8))
    device_params = arrays.get("device_params", np.empty((0, 5)))
    positions = arrays.get("device_positions", np.empty((0, 2)))

    for i in range(num_devices):
        # One-hot device type
        if i < device_types.size:
            t = int(device_types[i])
            if t < 16:
                node_features[i, t] = 1.0

        # Device parameters: W, L, fingers, mult, value
        if i < device_params.shape[0]:
            node_features[i, 16:21] = device_params[i, :5]

        # Position
        if i < positions.shape[0]:
            node_features[i, 21:23] = positions[i, :2]

    # ── Edge index and features ──────────────────────────────────────
    pin_device = arrays.get("pin_device", np.empty(0, dtype=np.uint32))
    pin_net = arrays.get("pin_net", np.empty(0, dtype=np.uint32))
    pin_terminal = arrays.get("pin_terminal", np.empty(0, dtype=np.uint8))

    # Edge index: [device_idx, net_idx] for each pin
    if num_pins > 0 and pin_device.size > 0 and pin_net.size > 0:
        edge_index = np.stack(
            [pin_device.astype(np.int64), pin_net.astype(np.int64)], axis=0
        )
    else:
        edge_index = np.empty((2, 0), dtype=np.int64)

    # Edge features: terminal type one-hot (max 8 types: G, D, S, B, +, -, A, K)
    edge_feat_dim = 8
    edge_features = np.zeros((num_pins, edge_feat_dim), dtype=np.float32)
    if pin_terminal.size > 0:
        for i in range(min(num_pins, pin_terminal.size)):
            t = int(pin_terminal[i])
            if t < edge_feat_dim:
                edge_features[i, t] = 1.0

    # Labels: placement cost as a scalar graph-level label
    labels = np.array([placement_cost], dtype=np.float32)

    return GraphFeatures(
        node_features=node_features,
        edge_index=edge_index,
        edge_features=edge_features,
        labels=labels,
        design_name=design_name,
    )


# ---------------------------------------------------------------------------
# Single-design harvest
# ---------------------------------------------------------------------------


def harvest_design(
    netlist_path: str,
    pdk: str = "sky130",
    backend: str = "magic",
    run_placement: bool = True,
    ffi=None,
) -> HarvestResult:
    """Parse a netlist, optionally run placement, and extract all features.

    Parameters
    ----------
    netlist_path : str
        Path to the SPICE netlist.
    pdk : str
        PDK name (``"sky130"``, ``"gf180"``, ``"ihp130"``).
    backend : str
        Backend name (``"magic"``, ``"klayout"``).
    run_placement : bool
        Whether to run SA placement (needed for cost labels).
    ffi : SpoutFFI or None
        Pre-initialised FFI instance.

    Returns
    -------
    HarvestResult
        All extracted features for this design.
    """
    from ..config import SpoutConfig, SaConfig
    from ..ffi import SpoutFFI

    design_name = Path(netlist_path).stem
    netlist_path = os.path.abspath(netlist_path)

    if not os.path.isfile(netlist_path):
        return HarvestResult(
            design_name=design_name,
            netlist_path=netlist_path,
            error=f"Netlist not found: {netlist_path}",
        )

    if ffi is None:
        try:
            ffi = SpoutFFI()
        except OSError as exc:
            return HarvestResult(
                design_name=design_name,
                netlist_path=netlist_path,
                error=f"Cannot load libspout.so: {exc}",
            )

    config = SpoutConfig(backend=backend, pdk=pdk)
    handle = ffi.init_layout(config.backend_id, config.pdk_id)

    try:
        # Parse netlist
        ffi.parse_netlist(handle, netlist_path)

        # Extract constraints
        ffi.extract_constraints(handle)

        # Optional placement
        placement_cost = 0.0
        if run_placement:
            sa_config = SaConfig(max_iterations=10_000)  # faster for harvesting
            ffi.run_sa_placement(handle, sa_config.to_ffi_bytes())
            placement_cost = ffi.get_placement_cost(handle)

        # Get all arrays
        arrays = ffi.get_all_arrays(handle)

        # Extract features
        surrogate = extract_surrogate_features(
            arrays, placement_cost=placement_cost, design_name=design_name
        )
        graph = extract_graph_features(
            arrays, placement_cost=placement_cost, design_name=design_name
        )

        return HarvestResult(
            design_name=design_name,
            netlist_path=netlist_path,
            surrogate=surrogate,
            graph=graph,
            placement_cost=placement_cost,
            success=True,
        )

    except Exception as exc:
        logger.exception("Failed to harvest %s", netlist_path)
        return HarvestResult(
            design_name=design_name,
            netlist_path=netlist_path,
            error=str(exc),
        )
    finally:
        ffi.destroy(handle)


# ---------------------------------------------------------------------------
# Batch harvest
# ---------------------------------------------------------------------------


def batch_harvest(
    input_dir: str,
    output_dir: str,
    pdk: str = "sky130",
    backend: str = "magic",
    run_placement: bool = True,
    extensions: tuple[str, ...] = (".spice", ".sp", ".cdl", ".cir"),
    output_format: str = "npz",
) -> list[HarvestResult]:
    """Process all netlists in a directory and save features.

    Parameters
    ----------
    input_dir : str
        Directory containing SPICE netlists.
    output_dir : str
        Directory to write feature files.
    pdk : str
        PDK name.
    backend : str
        Backend name.
    run_placement : bool
        Whether to run SA placement for cost labels.
    extensions : tuple of str
        File extensions to treat as netlists.
    output_format : str
        ``"npz"`` or ``"json"``.

    Returns
    -------
    list of HarvestResult
        Results for each processed design.
    """
    from ..ffi import SpoutFFI

    input_dir = os.path.abspath(input_dir)
    output_dir = os.path.abspath(output_dir)
    os.makedirs(output_dir, exist_ok=True)

    if not os.path.isdir(input_dir):
        raise FileNotFoundError(f"Input directory not found: {input_dir}")

    # Collect netlist files
    netlist_files = sorted(
        f
        for f in os.listdir(input_dir)
        if any(f.lower().endswith(ext) for ext in extensions)
    )

    if not netlist_files:
        logger.warning("No netlist files found in %s", input_dir)
        return []

    logger.info(
        "Harvesting %d designs from %s -> %s",
        len(netlist_files),
        input_dir,
        output_dir,
    )

    # Share a single FFI instance across all designs
    try:
        ffi = SpoutFFI()
    except OSError as exc:
        logger.error("Cannot load libspout.so: %s", exc)
        return [
            HarvestResult(
                design_name=Path(f).stem,
                netlist_path=os.path.join(input_dir, f),
                error=str(exc),
            )
            for f in netlist_files
        ]

    results: list[HarvestResult] = []
    surrogate_vectors: list[np.ndarray] = []
    design_names: list[str] = []

    for i, fname in enumerate(netlist_files):
        netlist_path = os.path.join(input_dir, fname)
        logger.info("[%d/%d] Harvesting %s", i + 1, len(netlist_files), fname)

        result = harvest_design(
            netlist_path,
            pdk=pdk,
            backend=backend,
            run_placement=run_placement,
            ffi=ffi,
        )
        results.append(result)

        if result.success and result.surrogate is not None:
            surrogate_vectors.append(result.surrogate.vector)
            design_names.append(result.design_name)

            # Save individual graph features
            if result.graph is not None:
                _save_graph_features(result.graph, output_dir, output_format)

    # Save surrogate feature matrix (all designs stacked)
    if surrogate_vectors:
        matrix = np.stack(surrogate_vectors, axis=0)  # (N, 69)
        surrogate_path = os.path.join(output_dir, "surrogate_features")

        if output_format == "npz":
            np.savez_compressed(
                surrogate_path + ".npz",
                features=matrix,
                design_names=np.array(design_names),
            )
        elif output_format == "json":
            data = {
                "design_names": design_names,
                "features": matrix.tolist(),
            }
            with open(surrogate_path + ".json", "w") as f:
                json.dump(data, f)

        logger.info(
            "Saved surrogate features: %s designs, shape %s",
            len(surrogate_vectors),
            matrix.shape,
        )

    # Summary
    successes = sum(1 for r in results if r.success)
    failures = len(results) - successes
    logger.info(
        "Harvest complete: %d/%d succeeded, %d failed",
        successes,
        len(results),
        failures,
    )

    return results


def _save_graph_features(
    graph: GraphFeatures, output_dir: str, output_format: str
) -> None:
    """Save a single design's graph features to disk.

    Args:
        graph: The ``GraphFeatures`` to serialise.
        output_dir: Directory to write the output file into.
        output_format: ``"npz"`` or ``"json"``.
    """
    name = graph.design_name or "unnamed"
    path = os.path.join(output_dir, f"graph_{name}")

    if output_format == "npz":
        save_dict = {
            "node_features": graph.node_features,
            "edge_index": graph.edge_index,
            "edge_features": graph.edge_features,
        }
        if graph.labels is not None:
            save_dict["labels"] = graph.labels
        np.savez_compressed(path + ".npz", **save_dict)
    elif output_format == "json":
        data = {
            "node_features": graph.node_features.tolist(),
            "edge_index": graph.edge_index.tolist(),
            "edge_features": graph.edge_features.tolist(),
            "labels": graph.labels.tolist() if graph.labels is not None else None,
            "design_name": graph.design_name,
        }
        with open(path + ".json", "w") as f:
            json.dump(data, f)


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------


def main() -> None:
    """Command-line interface for batch feature harvesting."""
    import argparse

    parser = argparse.ArgumentParser(
        description="Spout2 training data harvester: extract ML features from SPICE netlists"
    )
    parser.add_argument(
        "input_dir",
        help="Directory containing SPICE netlist files",
    )
    parser.add_argument(
        "-o",
        "--output",
        default="harvest_output",
        help="Output directory for feature files (default: harvest_output)",
    )
    parser.add_argument(
        "-p",
        "--pdk",
        default="sky130",
        choices=["sky130", "gf180", "ihp130"],
        help="PDK name (default: sky130)",
    )
    parser.add_argument(
        "-b",
        "--backend",
        default="magic",
        choices=["magic", "klayout"],
        help="Layout backend (default: magic)",
    )
    parser.add_argument(
        "--no-placement",
        action="store_true",
        help="Skip SA placement (no cost labels)",
    )
    parser.add_argument(
        "--format",
        default="npz",
        choices=["npz", "json"],
        help="Output format (default: npz)",
    )
    parser.add_argument(
        "-v",
        "--verbose",
        action="store_true",
        help="Verbose logging",
    )

    args = parser.parse_args()

    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
    )

    results = batch_harvest(
        input_dir=args.input_dir,
        output_dir=args.output,
        pdk=args.pdk,
        backend=args.backend,
        run_placement=not args.no_placement,
        output_format=args.format,
    )

    # Print summary
    successes = [r for r in results if r.success]
    failures = [r for r in results if not r.success]

    print(f"\nHarvest summary: {len(successes)}/{len(results)} designs processed")
    if failures:
        print("Failed designs:")
        for r in failures:
            print(f"  {r.design_name}: {r.error}")


if __name__ == "__main__":
    main()
