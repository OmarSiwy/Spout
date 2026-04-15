"""TinyTapeout-specific helpers for Spout integration.

Provides convenience wrappers for submitting analog layouts to TinyTapeout.
TinyTapeout uses a standardised GDS wrapper (user_project_wrapper) with a
user area of 160 µm × 100 µm per tile.

Usage::

    from python.tinytapeout import run_tinytapeout_pipeline

    result = run_tinytapeout_pipeline(
        netlist_path="my_circuit.spice",
        template_gds="tt_um_wrapper.gds",
        output_path="submission.gds",
    )
"""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
from typing import Optional

from .main import TemplateConfig, run_pipeline
from .config import SpoutConfig, SaConfig


# ---------------------------------------------------------------------------
# TinyTapeout dimensional constants
# ---------------------------------------------------------------------------

# User area per tile in microns.
TT_TILE_WIDTH_UM: float = 160.0
TT_TILE_HEIGHT_UM: float = 100.0

# GDS layer used for M1 routing in TinyTapeout analog tiles.
# GDS layer 68, datatype 20 = sky130 M1.
TT_ANALOG_METAL_LAYER: int = 68

# Name of the top-level wrapper cell in the TinyTapeout GDS template.
TT_WRAPPER_CELL: str = "user_project_wrapper"


# ---------------------------------------------------------------------------
# Public helpers
# ---------------------------------------------------------------------------


def tinytapeout_template_config(
    gds_path: str,
    num_tiles_x: int = 1,
    num_tiles_y: int = 1,
) -> TemplateConfig:
    """Create a TemplateConfig for a TinyTapeout submission.

    Parameters
    ----------
    gds_path : str
        Path to the TinyTapeout GDS template.  Download from
        ``tinytapeout.com`` or use the ``tt-gds-action`` output.
    num_tiles_x : int
        Number of horizontal tiles (1, 2, or 4).
    num_tiles_y : int
        Number of vertical tiles (1 or 2).

    Returns
    -------
    TemplateConfig
        Configured for the TinyTapeout ``user_project_wrapper`` cell.
    """
    # num_tiles_x / num_tiles_y currently informational — the actual bounds
    # are read from the template GDS at runtime via spout_get_template_bounds.
    _ = num_tiles_x
    _ = num_tiles_y

    return TemplateConfig(
        gds_path=gds_path,
        cell_name=TT_WRAPPER_CELL,
        user_area_origin=(0.0, 0.0),
    )


def run_tinytapeout_pipeline(
    netlist_path: str,
    template_gds: str,
    output_path: str = "submission.gds",
    config: Optional[SpoutConfig] = None,
    num_tiles_x: int = 1,
    num_tiles_y: int = 1,
):
    """Run the Spout pipeline targeting a TinyTapeout submission.

    Convenience wrapper around :func:`python.main.run_pipeline` that:

    - Configures the template as the TinyTapeout ``user_project_wrapper``
    - Applies tight SA perturbation range suited to the small tile area
    - Uses hierarchical GDSII export so the submitted GDS has the required
      ``top`` → ``user_project_wrapper`` + ``user_analog_circuit`` hierarchy

    Parameters
    ----------
    netlist_path : str
        SPICE netlist of the user analog circuit.
    template_gds : str
        Path to the TinyTapeout GDS template file.
    output_path : str
        Output GDSII file path for the submission package.
    config : SpoutConfig or None
        Full pipeline configuration.  A sensible default is used when
        *None*, with SA settings appropriate for a 160 × 100 µm tile.
    num_tiles_x : int
        Number of horizontal tiles (1, 2, or 4).
    num_tiles_y : int
        Number of vertical tiles (1 or 2).

    Returns
    -------
    PipelineResult
        Aggregated pipeline outcome.
    """
    if config is None:
        # Default SA parameters tuned for a small TinyTapeout tile area.
        sa = SaConfig(
            initial_temp=500.0,
            cooling_rate=0.995,
            min_temp=0.01,
            max_iterations=30_000,
            perturbation_range=5.0,   # µm — appropriate for 160 × 100 µm tile
            w_hpwl=1.0,
            w_overlap=100.0,
            w_symmetry=2.0,
        )
        config = SpoutConfig(
            pdk="sky130",
            sa_config=sa,
        )

    template = tinytapeout_template_config(template_gds, num_tiles_x, num_tiles_y)

    return run_pipeline(
        netlist_path=netlist_path,
        config=config,
        output_path=output_path,
        template_config=template,
    )
