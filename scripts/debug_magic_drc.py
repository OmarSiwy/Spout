#!/usr/bin/env python3
"""Debug script: dump raw MAGIC DRC output to understand TCL list format."""
import os, pathlib, subprocess, sys, tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "python"))

if "spout" not in sys.modules:
    import importlib.util
    spec = importlib.util.spec_from_file_location(
        "spout", str(ROOT / "python" / "__init__.py"),
        submodule_search_locations=[str(ROOT / "python")],
    )
    if spec and spec.loader:
        mod = importlib.util.module_from_spec(spec)
        sys.modules["spout"] = mod
        spec.loader.exec_module(mod)

from spout.config import SpoutConfig, SaConfig
from spout.pipeline import run_pipeline

BENCHMARKS_DIR = ROOT / "fixtures" / "benchmark"
pdk_root = os.environ.get("PDK_ROOT", "")
tech_file = pathlib.Path(pdk_root) / "sky130A" / "libs.tech" / "magic" / "sky130A.tech"

# Generate GDS
with tempfile.TemporaryDirectory() as tmp:
    netlist = BENCHMARKS_DIR / "current_mirror.spice"
    sa = SaConfig(max_iterations=500, cooling_rate=0.95, initial_temp=100.0)
    config = SpoutConfig(backend="klayout", pdk="sky130", sa_config=sa,
                         use_ml=False, use_gradient=False, use_repair=False)
    gds_path = str(pathlib.Path(tmp) / "test.gds")
    result = run_pipeline(str(netlist), config, output_path=gds_path)
    print(f"Spout DRC: {result.drc_violations}")

    # Run MAGIC with debug TCL
    tcl = f"""\
tech load {tech_file}
gds read {gds_path}
load current_mirror
select top cell
drc check
drc catchup
puts "=== RAW COUNT ==="
set cr [drc listall count]
puts "count_result: $cr"
puts "count_llength: [llength $cr]"
puts "=== ITERATE COUNT ==="
foreach {{cell cnt}} $cr {{
    puts "  CELL: $cell | COUNT: $cnt"
}}
puts "=== RAW WHY ==="
set wr [drc listall why]
puts "why_llength: [llength $wr]"
puts "=== ITERATE WHY ==="
foreach {{rule rects}} $wr {{
    set nr [expr {{[llength $rects] / 4}}]
    puts "  RULE: $rule | RECTS: $nr | RAW_LEN: [llength $rects]"
}}
puts "=== DONE ==="
quit
"""
    r = subprocess.run(["magic", "-dnull", "-noconsole"],
                       input=tcl, capture_output=True, text=True, timeout=120)
    print("\n=== MAGIC STDOUT ===")
    for line in r.stdout.splitlines():
        if any(x in line for x in ["===", "count_", "why_", "CELL:", "RULE:", "MAGIC"]):
            print(line)
    if r.stderr.strip():
        print("\n=== MAGIC STDERR (last 20 lines) ===")
        for line in r.stderr.splitlines()[-20:]:
            print(line)
