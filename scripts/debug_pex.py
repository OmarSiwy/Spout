#!/usr/bin/env python3
"""Run PEX on five_transistor_ota and print debug output."""
import sys, pathlib, tempfile, os, importlib.util

ROOT = pathlib.Path(__file__).resolve().parent.parent
_python_dir = str(ROOT / "python")
if _python_dir not in sys.path:
    sys.path.insert(0, _python_dir)
if "spout" not in sys.modules:
    spec = importlib.util.spec_from_file_location(
        "spout", str(ROOT / "python" / "__init__.py"),
        submodule_search_locations=[_python_dir],
    )
    if spec and spec.loader:
        mod = importlib.util.module_from_spec(spec)
        sys.modules["spout"] = mod
        spec.loader.exec_module(mod)

from spout.config import SpoutConfig, SaConfig
from spout.pipeline import run_pipeline

sa = SaConfig(max_iterations=500, cooling_rate=0.95, initial_temp=100.0)
cfg = SpoutConfig(backend="klayout", pdk="sky130", sa_config=sa,
                  use_ml=False, use_gradient=False, use_repair=False)
netlist = str(pathlib.Path(__file__).resolve().parent.parent / "fixtures" / "benchmark" / "five_transistor_ota.spice")
with tempfile.TemporaryDirectory() as tmp:
    result = run_pipeline(netlist, cfg, output_path=os.path.join(tmp, "out.gds"))
    print(f"Caps={result.pex_parasitic_caps} Res={result.pex_parasitic_res}")
    if result.pex_assessment:
        print(f"Total C={result.pex_assessment.total_cap_ff:.3f} fF")
