"""Spout pipeline — drives the full analog layout flow.

Coordinates: netlist parsing -> constraint extraction -> (optional ML encode) ->
SA placement -> (optional gradient refinement) -> routing -> GDSII export ->
signoff verification -> (optional ML repair loop).

Also provides the CLI entry point (main()).
"""


from __future__ import annotations

import argparse
import ctypes
import json
import logging
import os
import re
import sys
import time
from dataclasses import dataclass, field, replace
from pathlib import Path
from typing import Optional

from .config import SpoutConfig
from .ffi import SpoutFFI
from .tools import run_klayout_drc, run_klayout_lvs, run_magic_ext2spice

logger = logging.getLogger(__name__)


# ---------------------------------------------------------------------------
# Template configuration
# ---------------------------------------------------------------------------


@dataclass
class TemplateConfig:
    """Configuration for GDS template integration (e.g. TinyTapeout).

    Attributes
    ----------
    gds_path : str
        Path to the GDS template file (e.g. TinyTapeout wrapper GDS).
    cell_name : str or None
        Cell name to use as the user area.  When None the largest cell in
        the template is selected automatically.
    user_area_origin : tuple[float, float]
        (x, y) in microns where the user circuit is placed inside the
        template's user area.  (0.0, 0.0) means origin of user area.
    """

    gds_path: str
    cell_name: Optional[str] = None
    user_area_origin: tuple = (0.0, 0.0)


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
    """Extract the last ``.subckt`` name from a SPICE netlist."""
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
    template_config: Optional[TemplateConfig] = None,
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
    template_config : TemplateConfig or None
        Optional GDS template configuration.  When provided, the layout is
        constrained to the template's user area and the output GDSII
        contains a hierarchy referencing the template cell.

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

        # ── 2b. (Optional) Load GDS template ─────────────────────────
        if template_config:
            logger.info("Loading GDS template: %s", template_config.gds_path)
            gds_path_bytes = template_config.gds_path.encode("utf-8") + b"\x00"
            cell_name_bytes = (
                template_config.cell_name.encode("utf-8") + b"\x00"
                if template_config.cell_name
                else None
            )
            ret = ffi.lib.spout_load_template_gds(
                handle,
                gds_path_bytes,
                cell_name_bytes,
            )
            if ret != 0:
                raise RuntimeError(
                    f"Failed to load template GDS '{template_config.gds_path}': error {ret}"
                )
            logger.info("Template GDS loaded successfully")

            # Retrieve template bounds and apply as hard placement constraints.
            xmin = ctypes.c_float(0.0)
            ymin = ctypes.c_float(0.0)
            xmax = ctypes.c_float(0.0)
            ymax = ctypes.c_float(0.0)
            bounds_ret = ffi.lib.spout_get_template_bounds(
                handle,
                ctypes.byref(xmin),
                ctypes.byref(ymin),
                ctypes.byref(xmax),
                ctypes.byref(ymax),
            )
            if bounds_ret == 0:
                logger.info(
                    "Template bounds: xmin=%.2f ymin=%.2f xmax=%.2f ymax=%.2f µm",
                    xmin.value, ymin.value, xmax.value, ymax.value,
                )
                # Template hard bounds are applied automatically in Zig:
                # spout_run_sa_placement reads ctx.template_context directly
                # and sets use_template_bounds before running the SA.
            else:
                logger.warning("Could not retrieve template bounds (code %d)", bounds_ret)

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
        cell_name = _extract_subckt_name(netlist_path)
        logger.info("Exporting GDSII to %s (cell=%s)", output_path, cell_name or "<from-path>")

        if template_config:
            # Hierarchical export: user circuit cell + top cell that
            # references both the template cell and the user circuit.
            user_cell = cell_name if cell_name else "user_analog_circuit"
            top_cell = "top"
            logger.info(
                "Using hierarchical GDSII export (user_cell=%s, top_cell=%s)",
                user_cell, top_cell,
            )
            t0 = time.monotonic()
            out_path_bytes = output_path.encode("utf-8") + b"\x00"
            user_cell_bytes = user_cell.encode("utf-8") + b"\x00"
            top_cell_bytes = top_cell.encode("utf-8") + b"\x00"
            ret = ffi.lib.spout_export_gdsii_with_template(
                handle,
                out_path_bytes,
                user_cell_bytes,
                top_cell_bytes,
            )
            timings.export = time.monotonic() - t0
            if ret != 0:
                raise RuntimeError(
                    f"Hierarchical GDSII export failed with code {ret}"
                )
            cell_name = top_cell
        else:
            _, timings.export = _timed(ffi.export_gdsii, handle, output_path, cell_name)

        # ── 8. Signoff DRC (KLayout) ─────────────────────────────────
        logger.info("Running KLayout DRC")
        t0 = time.monotonic()
        cell_for_signoff = cell_name or Path(output_path).stem
        drc_violations = run_klayout_drc(output_path, cell_for_signoff)
        timings.drc = time.monotonic() - t0
        logger.info("DRC violations: %d", drc_violations)

        # ── 8b. Signoff LVS (KLayout) ───────────────────────────────
        t0 = time.monotonic()
        lvs_clean = False
        try:
            lvs_result = run_klayout_lvs(output_path, netlist_path, cell_for_signoff)
            if "error" in lvs_result:
                raise RuntimeError(lvs_result["error"])
            lvs_clean = lvs_result["match"]
            if not lvs_clean:
                sys.stdout.write(f"DEBUG LVS details:\n{lvs_result.get('details', '')[:3000]}\n")
                sys.stdout.flush()
                logger.warning("KLayout LVS FAILED — full output:\n%s", lvs_result.get("details", ""))
            logger.info("KLayout LVS: %s", "PASS" if lvs_clean else "FAIL")
        except Exception as exc:
            logger.warning("KLayout LVS failed (%s)", exc)
            lvs_clean = False
        timings.lvs = time.monotonic() - t0

        # ── 8c. Signoff PEX (Magic ext2spice) ────────────────────────
        pex_parasitic_caps = 0
        pex_parasitic_res = 0
        pex_assessment = None
        t0 = time.monotonic()
        try:
            pex_result = run_magic_ext2spice(output_path, cell_for_signoff, str(Path(output_path).parent))
            if "error" in pex_result:
                raise RuntimeError(pex_result["error"])
            pex_parasitic_caps = pex_result["num_cap"]
            pex_parasitic_res = pex_result["num_res"]
            logger.info("Magic PEX: %d caps, %d res", pex_parasitic_caps, pex_parasitic_res)
            pex_assessment = _assess_pex(pex_parasitic_caps, pex_parasitic_res, 0.0, 0.0)
            if pex_assessment:
                logger.info("PEX quality: %s", pex_assessment.rating.upper())
        except Exception as exc:
            logger.warning("Magic PEX failed (%s); skipping", exc)
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
    """Run the GNN encoder to inject ML predictions."""
    import numpy as np

    arrays = ffi.get_all_arrays(handle)
    num_devices = arrays["num_devices"]
    num_nets = arrays["num_nets"]

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
    """Iteratively apply ML-predicted repairs until DRC is clean."""
    violations = initial_violations

    for iteration in range(1, config.max_repair_iterations + 1):
        if violations == 0:
            break

        logger.info("Repair iteration %d / %d (%d violations remaining)",
                     iteration, config.max_repair_iterations, violations)

        try:
            from .unet.train import predict_repair  # type: ignore[import]

            drc_data = ffi.get_drc_violations(handle)
            positions = ffi.get_device_positions(handle)
            repair_deltas = predict_repair(positions, drc_data)

            repair_json = json.dumps(
                {"repair_deltas": repair_deltas.tolist()},
                separators=(",", ":"),
            ).encode("utf-8")
            ffi.set_constraints_from_ml(handle, repair_json)

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
            violations = run_klayout_drc(output_path, cell_name)
            if violations == -1:
                ffi.run_drc(handle)
                violations = ffi.get_num_violations(handle)

        except ImportError:
            logger.warning("UNet repair model not available; aborting repair loop")
            break
        except Exception as exc:
            logger.warning("Repair iteration %d failed: %s", iteration, exc)
            break

    return iteration if violations == 0 else config.max_repair_iterations


# ---------------------------------------------------------------------------
# CLI entry point
# ---------------------------------------------------------------------------


def main() -> None:
    """Command-line entry point for running the Spout2 pipeline."""
    parser = argparse.ArgumentParser(
        description="Spout2 analog layout automation pipeline"
    )
    parser.add_argument("netlist", help="Path to SPICE netlist")
    parser.add_argument(
        "-o", "--output", default="output.gds", help="Output GDSII path"
    )
    parser.add_argument(
        "-p", "--pdk", default="sky130", choices=["sky130", "gf180", "ihp130"],
        help="Process design kit",
    )
    parser.add_argument("--ml", action="store_true", help="Enable ML encode")
    parser.add_argument(
        "--moead",
        action="store_true",
        help="Use MOEA/D placement when the loaded library exposes it",
    )
    parser.add_argument(
        "--pareto",
        action="store_true",
        help="Dump Pareto front plots after MOEA/D placement",
    )
    parser.add_argument(
        "--pareto-dir",
        default=".",
        metavar="DIR",
        help="Directory to save Pareto front plots (default: current directory)",
    )
    parser.add_argument(
        "--detailed-routing",
        action="store_true",
        help="Use detailed routing when the loaded library exposes it",
    )
    parser.add_argument(
        "--gradient", action="store_true", help="Enable gradient refinement"
    )
    parser.add_argument(
        "--repair", action="store_true", help="Enable ML repair loop"
    )
    parser.add_argument(
        "--max-repair", type=int, default=5,
        help="Max repair iterations (default: 5)",
    )
    parser.add_argument("--pdk-root", default=None, help="PDK root directory")
    parser.add_argument(
        "--template-gds",
        default=None,
        metavar="GDS",
        help="GDS template file (e.g. TinyTapeout wrapper). When provided, "
             "placement is constrained to the template user area and the "
             "output includes a hierarchy referencing the template cell.",
    )
    parser.add_argument(
        "--template-cell",
        default=None,
        metavar="CELL",
        help="Cell name in the template GDS to use as the user area "
             "(default: auto-detect largest cell).",
    )
    parser.add_argument(
        "-v", "--verbose", action="store_true", help="Verbose logging"
    )

    args = parser.parse_args()

    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
    )

    config = SpoutConfig(
        pdk=args.pdk,
        use_ml=args.ml,
        use_gradient=args.gradient,
        use_moead_placement=args.moead,
        use_detailed_routing=args.detailed_routing,
        use_repair=args.repair,
        max_repair_iterations=args.max_repair,
        pdk_root=args.pdk_root,
        dump_pareto=args.pareto,
        pareto_dir=args.pareto_dir,
    )

    template_cfg: Optional[TemplateConfig] = None
    if args.template_gds:
        template_cfg = TemplateConfig(
            gds_path=args.template_gds,
            cell_name=args.template_cell,
        )

    result = run_pipeline(
        args.netlist, config, output_path=args.output, template_config=template_cfg
    )

    print(f"\n{'='*60}")
    print(f"Pipeline {'PASSED' if result.success else 'FAILED'}")
    print(f"{'='*60}")
    print(f"  GDSII:           {result.gds_path}")
    print(f"  DRC violations:  {result.drc_violations}")
    print(f"  LVS clean:       {result.lvs_clean}")
    print(f"  Devices:         {result.num_devices}")
    print(f"  Nets:            {result.num_nets}")
    print(f"  Routes:          {result.num_routes}")
    print(f"  Placement cost:  {result.placement_cost:.4f}")
    print(f"  Repair iters:    {result.repair_iterations}")
    if result.pex_parasitic_caps or result.pex_parasitic_res:
        print(f"  Parasitic caps:  {result.pex_parasitic_caps}")
        print(f"  Parasitic res:   {result.pex_parasitic_res}")
        if result.pex_assessment:
            a = result.pex_assessment
            print(f"  PEX quality:     {a.rating.upper()}"
                  f"  (R: {a.total_res_ohm:.2f} Ohm, C: {a.total_cap_ff:.3f} fF)")
            for note in a.notes:
                print(f"                   - {note}")
    else:
        print("  PEX:             no parasitics extracted")
    print(f"  Total time:      {result.timings.total:.2f}s")
    if result.error:
        print(f"  Error:           {result.error}")
    print(f"{'='*60}")


if __name__ == "__main__":
    main()
