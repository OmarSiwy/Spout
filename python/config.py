"""Top-level configuration shared across python_refactor modules.

Spout2 configuration — backend, PDK, and pipeline option selection.

The backend and PDK enums mirror the Zig-side LayoutBackend and PdkId
values defined in src/core/types.zig.
"""


from __future__ import annotations

import ctypes
import json
import os
from dataclasses import dataclass
from typing import Optional


class _SaConfigC(ctypes.Structure):
    """C-ABI mirror of ``src/placer/types.zig:SaConfig``."""

    _fields_ = [
        ("initialTemp", ctypes.c_float),
        ("coolingRate", ctypes.c_float),
        ("minTemp", ctypes.c_float),
        ("maxIterations", ctypes.c_uint32),
        ("perturbationRange", ctypes.c_float),
        ("wHpwl", ctypes.c_float),
        ("wArea", ctypes.c_float),
        ("wSymmetry", ctypes.c_float),
        ("wMatching", ctypes.c_float),
        ("wRudy", ctypes.c_float),
        ("wOverlap", ctypes.c_float),
        ("wThermal", ctypes.c_float),
        ("wTiming", ctypes.c_float),
        ("wEmbedSimilarity", ctypes.c_float),
        ("wParasitic", ctypes.c_float),
        ("adaptiveCooling", ctypes.c_uint8),
        ("adaptiveWindow", ctypes.c_uint32),
        ("maxReheats", ctypes.c_uint32),
        ("reheatFraction", ctypes.c_float),
        ("stallWindowsBeforeReheat", ctypes.c_uint32),
        ("numStarts", ctypes.c_uint32),
        # Delay estimator parameters
        ("delayDriverR", ctypes.c_float),
        ("delayWireRPerUm", ctypes.c_float),
        ("delayWireCPerUm", ctypes.c_float),
        ("delayPinC", ctypes.c_float),
    ]


@dataclass
class SaConfig:
    """Simulated-annealing hyperparameters.

    Mirrors the Zig ``SaConfig`` extern struct expected by
    ``spout_run_sa_placement``.
    """

    initial_temp: float = 1000.0
    cooling_rate: float = 0.995
    min_temp: float = 0.01
    max_iterations: int = 50_000
    perturbation_range: float = 10.0  # microns
    # Cost-function weights
    w_hpwl: float = 1.0
    w_area: float = 0.5
    w_symmetry: float = 2.0
    w_matching: float = 1.5
    w_rudy: float = 0.3
    w_overlap: float = 100.0
    w_timing: float = 0.3
    w_thermal: float = 0.0
    w_embed_similarity: float = 0.5
    w_parasitic: float = 0.2
    adaptive_cooling: bool = True
    adaptive_window: int = 500
    max_reheats: int = 5
    reheat_fraction: float = 0.3
    stall_windows_before_reheat: int = 3
    num_starts: int = 1
    # Delay estimator parameters (mirrors SaConfig delay fields in types.zig)
    delay_driver_r: float = 500.0
    delay_wire_r_per_um: float = 0.125
    delay_wire_c_per_um: float = 0.2
    delay_pin_c: float = 1.0

    def to_json_bytes(self) -> bytes:
        """Serialise SA hyperparameters to compact UTF-8 JSON bytes."""
        d = {
            "initial_temp": self.initial_temp,
            "cooling_rate": self.cooling_rate,
            "min_temp": self.min_temp,
            "max_iterations": self.max_iterations,
            "perturbation_range": self.perturbation_range,
            "w_hpwl": self.w_hpwl,
            "w_area": self.w_area,
            "w_symmetry": self.w_symmetry,
            "w_matching": self.w_matching,
            "w_rudy": self.w_rudy,
        }
        return json.dumps(d, separators=(",", ":")).encode("utf-8")

    def to_ffi_bytes(self) -> bytes:
        """Serialise SA hyperparameters to the native C ABI expected by Zig."""
        return bytes(
            _SaConfigC(
                initialTemp=self.initial_temp,
                coolingRate=self.cooling_rate,
                minTemp=self.min_temp,
                maxIterations=self.max_iterations,
                perturbationRange=self.perturbation_range,
                wHpwl=self.w_hpwl,
                wArea=self.w_area,
                wSymmetry=self.w_symmetry,
                wMatching=self.w_matching,
                wRudy=self.w_rudy,
                wOverlap=self.w_overlap,
                wThermal=self.w_thermal,
                wTiming=self.w_timing,
                wEmbedSimilarity=self.w_embed_similarity,
                wParasitic=self.w_parasitic,
                adaptiveCooling=1 if self.adaptive_cooling else 0,
                adaptiveWindow=self.adaptive_window,
                maxReheats=self.max_reheats,
                reheatFraction=self.reheat_fraction,
                stallWindowsBeforeReheat=self.stall_windows_before_reheat,
                numStarts=self.num_starts,
                delayDriverR=self.delay_driver_r,
                delayWireRPerUm=self.delay_wire_r_per_um,
                delayWireCPerUm=self.delay_wire_c_per_um,
                delayPinC=self.delay_pin_c,
            )
        )


@dataclass
class SurrogateTrainConfig:
    """Auto-researched defaults for surrogate training."""
    batch_size: int = 64
    lr: float = 0.01
    epochs: int = 200
    patience: int = 20
    weight_decay: float = 1e-4


@dataclass
class ConstraintTrainConfig:
    """Auto-researched defaults for constraint training."""
    n_graphs: int = 1069
    lr: float = 0.009
    temperature: float = 0.08
    epochs: int = 200
    patience: int = 25


@dataclass
class GcnrlTrainConfig:
    """Auto-researched defaults for gcnrl training."""
    lr: float = 3e-4
    clip_eps: float = 0.2
    update_every: int = 10
    n_episodes: int = 500


@dataclass
class ParagraphTrainConfig:
    """Auto-researched defaults for ml_paragraph training."""
    n_graphs: int = 795
    lr: float = 0.01
    epochs: int = 200
    patience: int = 25


@dataclass
class UnetTrainConfig:
    """Auto-researched defaults for unet training."""
    batch_size: int = 4
    lr: float = 0.001
    mask_ratio: float = 0.2
    n_samples: int = 500
    epochs: int = 100
    patience: int = 20


@dataclass
class MacroDefinition:
    """A user-defined macro for repeated subcircuit layout reuse.

    Provide either gds_path (a pre-built GDSII layout) or placement
    (a dict mapping device names to (x, y) positions).
    """
    name: str = ""
    subcircuit: str = ""
    gds_path: Optional[str] = None
    placement: Optional[dict[str, tuple[float, float]]] = None


class SpoutConfig:
    """Top-level configuration for a Spout2 pipeline run.

    Parameters
    ----------
    backend : str
        Layout backend — ``"magic"`` or ``"klayout"``.
    pdk : str
        Process design kit — ``"sky130"``, ``"gf180"``, or ``"ihp130"``.
    use_ml : bool
        Enable ML-enhanced encode step (GNN embeddings + ParaGraph).
    use_gradient : bool
        Enable gradient refinement after SA placement.
    use_moead_placement : bool
        Prefer the MOEA/D placement entrypoint when the loaded library exposes it.
    use_detailed_routing : bool
        Prefer the detailed routing entrypoint when the loaded library exposes it.
    use_repair : bool
        Enable UNet-based DRC repair loop.
    max_repair_iterations : int
        Maximum number of repair-loop iterations.
    pdk_root : str or None
        Filesystem path to the PDK installation root.  Falls back to
        ``$PDK_ROOT`` if *None*.
    sa_config : SaConfig or None
        SA hyperparameters.  Defaults to ``SaConfig()``.
    output_dir : str
        Directory for intermediate and final output files.
    macros : list[MacroDefinition] or None
        User-defined macros for repeated subcircuit layout reuse.
    """

    BACKENDS = {"magic": 0, "klayout": 1}
    PDKS = {"sky130": 0, "gf180": 1, "ihp130": 2}

    # PDK variant names (used in $PDK_ROOT/<variant>/libs.tech/...)
    _PDK_VARIANTS = {
        "sky130": "sky130A",
        "gf180": "gf180mcuD",
        "ihp130": "ihp-sg13g2",
    }

    # Tech-file paths relative to $PDK_ROOT/<variant>/, keyed by (backend, pdk).
    _TECH_FILES = {
        ("magic", "sky130"): "libs.tech/magic/sky130A.tech",
        ("magic", "gf180"): "libs.tech/magic/gf180mcuD.tech",
        ("magic", "ihp130"): "libs.tech/magic/ihp-sg13g2.tech",
        ("klayout", "sky130"): "libs.tech/klayout/sky130A.lyt",
        ("klayout", "gf180"): "libs.tech/klayout/gf180mcuD.lyt",
        ("klayout", "ihp130"): "libs.tech/klayout/ihp-sg13g2.lyt",
    }

    # Netgen setup file paths relative to $PDK_ROOT/<variant>/
    _NETGEN_SETUP = {
        "sky130": "libs.tech/netgen/sky130A_setup.tcl",
        "gf180": "libs.tech/netgen/gf180mcuD_setup.tcl",
        "ihp130": "libs.tech/netgen/ihp-sg13g2_setup.tcl",
    }

    def __init__(
        self,
        backend: str = "magic",
        pdk: str = "sky130",
        use_ml: bool = False,
        use_gradient: bool = False,
        use_moead_placement: bool = False,
        use_detailed_routing: bool = False,
        use_repair: bool = False,
        max_repair_iterations: int = 5,
        dump_pareto: bool = False,
        pareto_dir: str = ".",
        pdk_root: Optional[str] = None,
        sa_config: Optional[SaConfig] = None,
        output_dir: str = "spout_output",
        macros: list[MacroDefinition] | None = None,
    ) -> None:
        if backend not in self.BACKENDS:
            raise ValueError(
                f"Unknown backend {backend!r}; choose from {list(self.BACKENDS)}"
            )
        if pdk not in self.PDKS:
            raise ValueError(
                f"Unknown PDK {pdk!r}; choose from {list(self.PDKS)}"
            )

        self.backend: str = backend
        self.pdk: str = pdk
        self.backend_id: int = self.BACKENDS[backend]
        self.pdk_id: int = self.PDKS[pdk]
        self.use_ml: bool = use_ml
        self.use_gradient: bool = use_gradient
        self.use_moead_placement: bool = use_moead_placement
        self.use_detailed_routing: bool = use_detailed_routing
        self.use_repair: bool = use_repair
        self.dump_pareto: bool = dump_pareto
        self.pareto_dir: str = pareto_dir
        self.max_repair_iterations: int = max_repair_iterations
        self.pdk_root: str = pdk_root or os.environ.get("PDK_ROOT", "")
        self.sa_config: SaConfig = sa_config or SaConfig()
        self.output_dir: str = output_dir
        self.macros: list[MacroDefinition] = macros or []

    @property
    def pdk_variant_root(self) -> str:
        """Absolute path to the PDK variant directory (e.g. $PDK_ROOT/sky130A)."""
        variant = self._PDK_VARIANTS.get(self.pdk, "")
        return os.path.join(self.pdk_root, variant) if self.pdk_root else ""

    @property
    def tech_file(self) -> str:
        """Absolute path to the tech file for the chosen (backend, pdk)."""
        rel = self._TECH_FILES.get((self.backend, self.pdk), "")
        base = self.pdk_variant_root
        return os.path.join(base, rel) if base else rel

    @property
    def netgen_setup(self) -> str:
        """Absolute path to the Netgen setup .tcl file."""
        rel = self._NETGEN_SETUP.get(self.pdk, "")
        base = self.pdk_variant_root
        return os.path.join(base, rel) if base else rel

    def __repr__(self) -> str:
        return (
            f"SpoutConfig(backend={self.backend!r}, pdk={self.pdk!r}, "
            f"use_ml={self.use_ml}, use_gradient={self.use_gradient}, "
            f"use_moead_placement={self.use_moead_placement}, "
            f"use_detailed_routing={self.use_detailed_routing}, "
            f"use_repair={self.use_repair})"
        )
