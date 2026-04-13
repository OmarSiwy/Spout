"""Spout pipeline orchestration — drives the full analog layout flow.

Coordinates: netlist parsing -> constraint extraction -> (optional ML encode) ->
SA placement -> (optional gradient refinement) -> routing -> GDSII export ->
signoff verification -> (optional ML repair loop).
"""


from __future__ import annotations

import json
import logging
import os
import re
import time
from dataclasses import dataclass, field, replace
from pathlib import Path
from typing import Optional

from .config import SpoutConfig
from .ffi import SpoutFFI

logger = logging.getLogger(__name__)


# ---------------------------------------------------------------------------
# Result types
# ---------------------------------------------------------------------------


@dataclass
class StageTimings:
    """Wall-clock seconds for each pipeline stage."""

    parse: float = 0.0
    constraints: float = 0.0
    ml_encode: float = 0.0
    placement: float = 0.0
    gradient: float = 0.0
    routing: float = 0.0
    export: float = 0.0
    drc: float = 0.0
    lvs: float = 0.0
    pex: float = 0.0
    repair: float = 0.0

    @property
    def total(self) -> float:
        from dataclasses import fields as _fields
        return sum(getattr(self, f.name) for f in _fields(self))


@dataclass
class PexAssessment:
    """Quality assessment of parasitic extraction results."""

    rating: str  # "good", "acceptable", "poor"
    total_res_ohm: float = 0.0
    total_cap_ff: float = 0.0
    max_res_ohm: float = 0.0
    max_res_layer: str = ""
    notes: list[str] = field(default_factory=list)


@dataclass
class PipelineResult:
    """Outcome of a complete Spout2 pipeline run."""

    gds_path: str
    drc_violations: int
    lvs_clean: bool
    success: bool
    error: Optional[str] = None
    placement_cost: float = 0.0
    num_devices: int = 0
    num_nets: int = 0
    num_routes: int = 0
    pex_spice_path: str = ""
    pex_parasitic_caps: int = 0
    pex_parasitic_res: int = 0
    pex_assessment: Optional[PexAssessment] = None
    repair_iterations: int = 0
    timings: StageTimings = field(default_factory=StageTimings)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _timed(fn, *args, **kwargs):
    """Call *fn* and return ``(result, elapsed_seconds)``."""
    t0 = time.monotonic()
    result = fn(*args, **kwargs)
    return result, time.monotonic() - t0


def _extract_subckt_name(netlist_path: str) -> str:
    """Extract the last ``.subckt`` name from a SPICE netlist.

    KLayout LVS expects the GDS top-cell name to match the schematic
    subcircuit name.  When there are nested subcircuits the last one is
    typically the top-level circuit.
    """
    name = ""
    try:
        with open(netlist_path, "r") as f:
            for line in f:
                m = re.match(r"\.subckt\s+(\S+)", line, re.IGNORECASE)
                if m:
                    name = m.group(1)
    except OSError:
        pass
    return name


def _dump_pareto_plots(ffi: SpoutFFI, handle, pareto_dir: str) -> None:
    """Dump Pareto front plots after a MOEA/D placement run."""
    try:
        from pathlib import Path
        from .utility.pareto import build_pareto_front, plot_pareto_2d, plot_pareto_3d

        objectives = ffi.get_pareto_objectives(handle)
        if objectives.shape[0] == 0:
            logger.info("Pareto front empty — skipping plots")
            return
        front = build_pareto_front(objectives)
        knee = front.find_knee_point()
        logger.info("Pareto front: %d solutions, knee index %d", front.size, knee)
        out = Path(pareto_dir)
        out.mkdir(parents=True, exist_ok=True)
        plot_pareto_2d(front, save_path=out / "pareto_2d.png", show=False)
        plot_pareto_3d(front, save_path=out / "pareto_3d.png", show=False)
        logger.info("Saved Pareto plots to %s", out)
    except Exception as exc:
        logger.warning("Pareto plot failed: %s", exc)


def _run_placement_stage(
    ffi: SpoutFFI, handle, config: SpoutConfig, config_json: bytes
) -> tuple[str, float]:
    """Run placement using the requested backend when the FFI supports it."""
    use_moead = (
        config.use_moead_placement
        and bool(getattr(ffi, "supports_moead_placement", False))
    )
    if config.use_moead_placement and not use_moead:
        logger.info("MOEA/D placement requested but unavailable; falling back to SA")

    if use_moead:
        logger.info("Running MOEA/D placement")
        _, elapsed = _timed(ffi.run_moead_placement, handle, config_json)
        if getattr(config, "dump_pareto", False):
            _dump_pareto_plots(ffi, handle, getattr(config, "pareto_dir", "."))
        return "moead", elapsed

    logger.info("Running simulated-annealing placement")
    _, elapsed = _timed(ffi.run_sa_placement, handle, config_json)
    return "sa", elapsed


def _run_routing_stage(ffi: SpoutFFI, handle, config: SpoutConfig) -> tuple[str, float]:
    """Run routing using the requested backend when the FFI supports it."""
    use_detailed = (
        config.use_detailed_routing
        and bool(getattr(ffi, "supports_detailed_routing", False))
    )
    if config.use_detailed_routing and not use_detailed:
        logger.info(
            "Detailed routing requested but unavailable; falling back to maze routing"
        )

    if use_detailed:
        logger.info("Running detailed routing")
        _, elapsed = _timed(ffi.run_detailed_routing, handle)
        return "detailed", elapsed

    logger.info("Running routing")
    _, elapsed = _timed(ffi.run_routing, handle)
    return "maze", elapsed


def _assess_pex(
    num_caps: int, num_res: int, total_cap_ff: float, total_res_ohm: float,
) -> Optional[PexAssessment]:
    """Assess in-engine PEX result quality from aggregate totals."""
    if num_caps == 0 and num_res == 0:
        return PexAssessment(rating="unknown", notes=["No parasitics extracted"])

    notes: list[str] = []
    if total_cap_ff > 100:
        notes.append(f"High total parasitic C ({total_cap_ff:.2f} fF) — may limit bandwidth")
    elif total_cap_ff < 1:
        notes.append(f"Total parasitic C: {total_cap_ff:.3f} fF — negligible")
    else:
        notes.append(f"Total parasitic C: {total_cap_ff:.2f} fF")

    if total_res_ohm > 200:
        notes.append(f"High total wire R ({total_res_ohm:.1f} Ohm) — consider wider routes")
    else:
        notes.append(f"Total wire R: {total_res_ohm:.2f} Ohm")

    has_broken = total_res_ohm > 500 or total_cap_ff > 1000
    has_severe = total_res_ohm > 200 or total_cap_ff > 500
    has_concerns = total_res_ohm > 50 or total_cap_ff > 100
    is_excellent = total_res_ohm < 15 and total_cap_ff < 1

    if has_broken:
        rating = "broken"
    elif has_severe:
        rating = "poor"
    elif has_concerns:
        rating = "acceptable"
    elif is_excellent:
        rating = "excellent"
    else:
        rating = "good"

    return PexAssessment(
        rating=rating,
        total_res_ohm=total_res_ohm,
        total_cap_ff=total_cap_ff,
        max_res_ohm=total_res_ohm,
        max_res_layer="",
        notes=notes,
    )


# ---------------------------------------------------------------------------
# Main pipeline
# ---------------------------------------------------------------------------


def run_pipeline(
    netlist_path: str,
    config: SpoutConfig,
    output_path: str = "output.gds",
    ffi: Optional[SpoutFFI] = None,
) -> PipelineResult:
    """Run the complete Spout2 layout automation pipeline.

    Parameters
    ----------
    netlist_path : str
        Path to a SPICE netlist (.spice / .sp / .cdl).
    config : SpoutConfig
        Pipeline configuration (backend, PDK, feature flags, etc.).
    output_path : str
        Destination path for the GDSII output.
    ffi : SpoutFFI or None
        Pre-initialised FFI handle.  A fresh one is created when *None*.

    Returns
    -------
    PipelineResult
        Aggregated outcome including DRC/LVS status, timings, and paths.
    """
    if ffi is None:
        ffi = SpoutFFI()

    timings = StageTimings()

    # Ensure output directory exists
    out_dir = os.path.dirname(os.path.abspath(output_path))
    os.makedirs(out_dir, exist_ok=True)

    handle = ffi.init_layout(
        config.BACKENDS[config.backend],
        config.PDKS[config.pdk],
    )

    try:
        # ── 1. Parse netlist ─────────────────────────────────────────
        logger.info("Parsing netlist: %s", netlist_path)
        _, timings.parse = _timed(ffi.parse_netlist, handle, netlist_path)
        num_devices = ffi.get_num_devices(handle)
        num_nets = ffi.get_num_nets(handle)
        logger.info(
            "Parsed %d devices, %d nets, %d pins",
            num_devices,
            num_nets,
            ffi.get_num_pins(handle),
        )

        # ── 2. Extract constraints ───────────────────────────────────
        logger.info("Extracting constraints")
        _, timings.constraints = _timed(ffi.extract_constraints, handle)

        # ── 3. (Optional) ML encode ──────────────────────────────────
        if config.use_ml:
            logger.info("Running ML encode step")
            t0 = time.monotonic()
            try:
                _run_ml_encode(ffi, handle)
            except Exception as exc:
                logger.warning(
                    "ML encode failed (%s); continuing without embeddings", exc
                )
            timings.ml_encode = time.monotonic() - t0

        # ── 4. Placement ─────────────────────────────────────────────
        sa_json = config.sa_config.to_ffi_bytes()
        placement_mode, timings.placement = _run_placement_stage(
            ffi, handle, config, sa_json
        )
        placement_cost = ffi.get_placement_cost(handle)
        logger.info("%s placement cost: %.4f", placement_mode.upper(), placement_cost)

        # ── 5. (Optional) Gradient refinement ────────────────────────
        if config.use_gradient:
            logger.info("Running gradient refinement")
            _, timings.gradient = _timed(
                ffi.run_gradient_refinement, handle
            )
            refined_cost = ffi.get_placement_cost(handle)
            logger.info(
                "Cost after gradient refinement: %.4f (delta %.4f)",
                refined_cost,
                placement_cost - refined_cost,
            )
            placement_cost = refined_cost

        # ── 6. Routing ───────────────────────────────────────────────
        routing_mode, timings.routing = _run_routing_stage(ffi, handle, config)
        num_routes = ffi.get_num_routes(handle)
        logger.info("%s routing generated %d route segments", routing_mode, num_routes)

        # ── 7. Export GDSII ──────────────────────────────────────────
        # Use the subcircuit name as the GDS cell name so it matches
        # the schematic for KLayout LVS.
        cell_name = _extract_subckt_name(netlist_path)
        logger.info("Exporting GDSII to %s (cell=%s)", output_path, cell_name or "<from-path>")
        _, timings.export = _timed(ffi.export_gdsii, handle, output_path, cell_name)

        # ── 8. In-engine DRC ─────────────────────────────────────────
        logger.info("Running in-engine DRC")
        t0 = time.monotonic()
        ffi.run_drc(handle)
        drc_violations = ffi.get_num_violations(handle)
        timings.drc = time.monotonic() - t0
        logger.info("In-engine DRC violations: %d", drc_violations)

        # ── 8b. In-engine LVS ────────────────────────────────────────
        t0 = time.monotonic()
        try:
            ffi.run_lvs(handle)
            lvs_clean = ffi.get_lvs_match(handle)
            mismatches = ffi.get_lvs_mismatch_count(handle)
            logger.info("In-engine LVS: %s (%d mismatches)", lvs_clean, mismatches)
        except Exception as exc:
            logger.warning("In-engine LVS failed (%s); marking unclean", exc)
            lvs_clean = False
        timings.lvs = time.monotonic() - t0

        # ── 8c. In-engine PEX ────────────────────────────────────────
        pex_parasitic_caps = 0
        pex_parasitic_res = 0
        pex_assessment = None
        t0 = time.monotonic()
        try:
            ffi.run_pex(handle)
            pex_data = ffi.get_pex_result(handle)
            pex_parasitic_caps = pex_data["num_caps"]
            pex_parasitic_res = pex_data["num_res"]
            logger.info(
                "In-engine PEX: %d caps, %d res, %.2f fF, %.2f Ohm",
                pex_parasitic_caps, pex_parasitic_res,
                pex_data["total_cap_ff"], pex_data["total_res_ohm"],
            )
            pex_assessment = _assess_pex(
                pex_parasitic_caps, pex_parasitic_res,
                pex_data["total_cap_ff"], pex_data["total_res_ohm"],
            )
            if pex_assessment:
                logger.info("PEX quality: %s", pex_assessment.rating.upper())
        except Exception as exc:
            logger.warning("In-engine PEX failed (%s); skipping", exc)
        timings.pex = time.monotonic() - t0

        # ── 9. (Optional) ML repair loop ─────────────────────────────
        repair_iterations = 0
        if config.use_repair and drc_violations > 0:
            logger.info("Entering ML repair loop (max %d iters)", config.max_repair_iterations)
            t0 = time.monotonic()
            repair_iterations = _run_repair_loop(
                ffi,
                handle,
                config,
                output_path,
                netlist_path,
                drc_violations,
            )
            timings.repair = time.monotonic() - t0
            # Re-check after repair
            drc_violations = ffi.get_num_violations(handle)
            logger.info(
                "After %d repair iterations: %d DRC violations",
                repair_iterations,
                drc_violations,
            )

        success = drc_violations == 0 and lvs_clean
        return PipelineResult(
            gds_path=os.path.abspath(output_path),
            drc_violations=drc_violations,
            lvs_clean=lvs_clean,
            success=success,
            placement_cost=placement_cost,
            num_devices=num_devices,
            num_nets=num_nets,
            num_routes=num_routes,
            pex_parasitic_caps=pex_parasitic_caps,
            pex_parasitic_res=pex_parasitic_res,
            pex_assessment=pex_assessment,
            repair_iterations=repair_iterations,
            timings=timings,
        )

    except Exception as exc:
        logger.exception("Pipeline failed")
        return PipelineResult(
            gds_path=output_path,
            drc_violations=-1,
            lvs_clean=False,
            success=False,
            error=str(exc),
            timings=timings,
        )
    finally:
        ffi.destroy(handle)


# ---------------------------------------------------------------------------
# ML encode helper
# ---------------------------------------------------------------------------


def _run_ml_encode(ffi: SpoutFFI, handle) -> None:
    """Run the GNN encoder to inject ML predictions.

    Imports the ML modules lazily so the pipeline can run without them.
    """
    import numpy as np

    arrays = ffi.get_all_arrays(handle)
    num_devices = arrays["num_devices"]
    num_nets = arrays["num_nets"]

    # Try to import and run the GNN constraint encoder
    try:
        from .constraint.model import ConstraintGraphSAGE  # type: ignore[import]
        from .constraint.train import encode_circuit  # type: ignore[import]

        device_emb, net_emb = encode_circuit(arrays)
        ffi.set_device_embeddings(handle, device_emb)
        ffi.set_net_embeddings(handle, net_emb)
        logger.info(
            "GNN embeddings set: devices %s, nets %s",
            device_emb.shape,
            net_emb.shape,
        )
    except (ImportError, Exception):
        logger.info("GNN encoder not available; using zero embeddings")
        ffi.set_device_embeddings(
            handle, np.zeros((num_devices, 64), dtype=np.float32)
        )
        ffi.set_net_embeddings(
            handle, np.zeros((num_nets, 64), dtype=np.float32)
        )

    # Try to import and run the ML constraint predictor
    try:
        from .constraint.model import predict_constraints, build_model  # type: ignore[import]
        from .constraint.train import build_graph  # type: ignore[import]

        model = build_model(device="cpu")
        graph_data = build_graph(arrays)
        pairs, scores = predict_constraints(
            model,
            graph_data["x"],
            graph_data["edge_index"],
            threshold=0.5,
            edge_attr=graph_data.get("edge_attr"),
        )
        if pairs.shape[0] > 0:
            import json as _json
            ml_constraints = [
                {
                    "device_a": int(pairs[k, 0]),
                    "device_b": int(pairs[k, 1]),
                    "type": 0,          # symmetry
                    "weight": float(scores[k]),
                    "group_id": 1,
                }
                for k in range(pairs.shape[0])
            ]
            ffi.add_constraints_from_ml(handle, _json.dumps(ml_constraints).encode())
            logger.info("ML added %d constraint pairs", pairs.shape[0])
    except (ImportError, Exception) as exc:
        logger.info("ML constraint augmentation skipped: %s", exc)


# ---------------------------------------------------------------------------
# Repair loop helper
# ---------------------------------------------------------------------------


def _run_repair_loop(
    ffi: SpoutFFI,
    handle,
    config: SpoutConfig,
    output_path: str,
    netlist_path: str,
    initial_violations: int,
) -> int:
    """Iteratively apply ML-predicted repairs until DRC is clean.

    Returns the number of repair iterations executed.
    """
    violations = initial_violations

    for iteration in range(1, config.max_repair_iterations + 1):
        if violations == 0:
            break

        logger.info("Repair iteration %d / %d (%d violations remaining)",
                     iteration, config.max_repair_iterations, violations)

        try:
            # Import the UNet repair model lazily
            from .unet.train import predict_repair  # type: ignore[import]

            drc_data = ffi.get_drc_violations(handle)
            positions = ffi.get_device_positions(handle)
            repair_deltas = predict_repair(positions, drc_data)

            # Apply the repair as constraint overrides
            repair_json = json.dumps(
                {"repair_deltas": repair_deltas.tolist()},
                separators=(",", ":"),
            ).encode("utf-8")
            ffi.set_constraints_from_ml(handle, repair_json)

            # Re-run placement with tighter perturbation for refinement
            refined_sa = replace(
                config.sa_config,
                perturbation_range=max(
                    0.5, config.sa_config.perturbation_range * 0.5
                ),
            )
            _run_placement_stage(ffi, handle, config, refined_sa.to_ffi_bytes())

            if config.use_gradient:
                ffi.run_gradient_refinement(handle)

            _run_routing_stage(ffi, handle, config)
            cell_name = _extract_subckt_name(netlist_path)
            ffi.export_gdsii(handle, output_path, cell_name)
            ffi.run_drc(handle)
            violations = ffi.get_num_violations(handle)

        except ImportError:
            logger.warning("UNet repair model not available; aborting repair loop")
            break
        except Exception as exc:
            logger.warning("Repair iteration %d failed: %s", iteration, exc)
            break

    return iteration if violations == 0 else config.max_repair_iterations
