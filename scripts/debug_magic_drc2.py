#!/usr/bin/env python3
"""Debug: dump raw MAGIC drc listall why rect data to understand format."""
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

with tempfile.TemporaryDirectory() as tmp:
    netlist = BENCHMARKS_DIR / "current_mirror.spice"
    sa = SaConfig(max_iterations=500, cooling_rate=0.95, initial_temp=100.0)
    config = SpoutConfig(backend="klayout", pdk="sky130", sa_config=sa,
                         use_ml=False, use_gradient=False, use_repair=False)
    gds_path = str(pathlib.Path(tmp) / "test.gds")
    run_pipeline(str(netlist), config, output_path=gds_path)

    # Dump raw rect data for each why rule, plus fix count parsing
    tcl = f"""\
tech load {tech_file}
gds read {gds_path}
load current_mirror
select top cell
drc check
drc catchup
# Fix count: it's a list of sublists {{cellname count}}
set cr [drc listall count]
set total 0
foreach item $cr {{
    set cnt [lindex $item 1]
    if {{$cnt ne ""}} {{
        set total [expr {{$total + $cnt}}]
        puts "COUNT_ITEM: [lindex $item 0] = $cnt"
    }}
}}
puts "TOTAL: $total"
# Dump first 20 elements of raw rect list for each rule
set wr [drc listall why]
set idx 0
foreach {{rule rects}} $wr {{
    puts "---"
    puts "RULE($idx): $rule"
    puts "  llength: [llength $rects]"
    puts "  first20: [lrange $rects 0 19]"
    puts "  last5: [lrange $rects end-4 end]"
    incr idx
}}
quit
"""
    r = subprocess.run(["magic", "-dnull", "-noconsole"],
                       input=tcl, capture_output=True, text=True, timeout=120)
    for line in r.stdout.splitlines():
        if any(x in line for x in ["COUNT_ITEM", "TOTAL:", "---", "RULE(", "llength", "first20", "last5"]):
            print(line)
